%%%-----------------------------------------------------------------------------
%%% @doc blockchain_poc_target_v5 implementation.
%%%
%%% The targeting mechanism is based on the following conditions:
%%% - Deterministically identify a target region based on public key
%%% - Deterministically select a challengee from target region based on private key
%%%
%%%-----------------------------------------------------------------------------
-module(blockchain_poc_target_v5).

-include("blockchain_utils.hrl").
-include("blockchain_vars.hrl").
-include("blockchain_caps.hrl").

-export([
    target_zone/2,
    gateways_for_zone/5,
    target/5
]).

-spec target_zone(
    RandState :: rand:state(),
    Ledger :: blockchain_ledger_v1:ledger()
) -> {ok, {[h3:h3_index()], h3:h3_index(), rand:state()}} | {error, any()}.
target_zone(RandState, Ledger) ->
    %% Get some random hexes
    {HexList, NewRandState} = hex_list(Ledger, RandState),
    %% Initialize seed with Hash once
    %% Initial zone to begin targeting into
    case choose_zone(NewRandState, HexList) of
        {error, _} = ErrorResp -> ErrorResp;
        {ok, {Hex, HexRandState}} -> {ok, {HexList, Hex, HexRandState}}
    end.

%% @doc Finds all valid gateways in specified zone
-spec gateways_for_zone(
    ChallengerPubkeyBin :: libp2p_crypto:pubkey_bin(),
    Ledger :: blockchain_ledger_v1:ledger(),
    Vars :: map(),
    HexList :: [h3:h3_index()],
    Attempted :: [{h3:h3_index(), rand:state()}]
) -> {ok, [libp2p_crypto:pubkey_bin()]} | {error, any()}.
gateways_for_zone(
    ChallengerPubkeyBin,
    Ledger,
    Vars,
    HexList,
    [{Hex, HexRandState0} | Tail] = _Attempted
) ->
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    %% Get a list of gateway pubkeys within this hex
    AddrMap = blockchain_ledger_v1:lookup_gateways_from_hex(Hex, Ledger),
    AddrList0 = lists:flatten(maps:values(AddrMap)),
    lager:info("gateways for hex ~p: ~p", [Hex, AddrList0]),
    %% Limit max number of potential targets in the zone
    {HexRandState, AddrList} = limit_addrs(Vars, HexRandState0, AddrList0),

    case filter(AddrList, Ledger, Height, Vars) of
        FilteredList when length(FilteredList) >= 1 ->
            lager:info("*** found gateways for hex ~p: ~p", [Hex, FilteredList]),
            {ok, FilteredList};
        _ ->
            lager:info("*** failed to find gateways for zone ~p, trying again", [Hex]),
            %% no eligible target in this zone
            %% find a new zone
            case choose_zone(HexRandState, HexList) of
                {error, _} = ErrorResp -> ErrorResp;
                {ok, New} ->
                    %% remove Hex from attempted, add New to attempted and retry
                    gateways_for_zone(ChallengerPubkeyBin, Ledger, Vars, HexList, [New | Tail])
            end


    end.

-spec target(
    ChallengerPubkeyBin :: libp2p_crypto:pubkey_bin(),
    InitTargetRandState :: rand:state(),
    ZoneRandState :: rand:state(),
    Ledger :: blockchain_ledger_v1:ledger(),
    Vars :: map()
) -> {ok, {libp2p_crypto:pubkey_bin(), rand:state()}} | {error, any()}.
target(ChallengerPubkeyBin, InitTargetRandState, ZoneRandState, Ledger, Vars) ->
    %% Initial zone to begin targeting into
    case target_zone(ZoneRandState, Ledger) of
        {error, _} = ErrorResp ->
            ErrorResp;
        {ok, {HexList, Hex, HexRandState}} ->
            lager:info("*** target got InitHex ~p and InitHexRandState ~p", [Hex, HexRandState]),
            target_(
                ChallengerPubkeyBin,
                InitTargetRandState,
                Ledger,
                Vars,
                HexList,
                Hex,
                HexRandState
            )
    end.

%% @doc Finds a potential target to start the path from.
-spec target_(
    ChallengerPubkeyBin :: libp2p_crypto:pubkey_bin(),
    InitTargetRandState :: rand:state(),
    Ledger :: blockchain_ledger_v1:ledger(),
    Vars :: map(),
    HexList :: [h3:h3_index()],
    InitHex :: h3:h3_index(),
    InitHexRandState :: rand:state()
) -> {ok, {libp2p_crypto:pubkey_bin(), rand:state()}}.
target_(
    ChallengerPubkeyBin,
    InitTargetRandState,
    Ledger,
    Vars,
    HexList,
    InitHex,
    InitHexRandState
) ->
    {ok, ZoneGWs} = gateways_for_zone(ChallengerPubkeyBin, Ledger, Vars, HexList, [
        {InitHex, InitHexRandState}
    ]),
    %% Assign probabilities to each of these gateways
    Prob = blockchain_utils:normalize_float(prob_randomness_wt(Vars) * 1.0),
    ProbTargets = lists:map(
        fun(A) ->
            {A, Prob}
        end,
        ZoneGWs),

    lager:info("*** ProbTargets ~p", [ProbTargets]),
    %% Sort the scaled probabilities in default order by gateway pubkey_bin
    %% make sure that we carry the rand_state through for determinism
    {RandVal, TargetRandState} = rand:uniform_s(InitTargetRandState),
    {ok, TargetPubkeybin} = blockchain_utils:icdf_select(
        lists:keysort(1, ProbTargets),
        RandVal
    ),
    {ok, {TargetPubkeybin, TargetRandState}}.

%% @doc Filter gateways based on these conditions:
%% - gateways which do not have the relevant capability
-spec filter(
    AddrList :: [libp2p_crypto:pubkey_bin()],
    Ledger :: blockchain_ledger_v1:ledger(),
    Height :: non_neg_integer(),
    Vars :: map()
) -> [libp2p_crypto:pubkey_bin()].
filter(AddrList, Ledger, _Height, _Vars) ->
    lists:filter(
        fun(A) ->
            {ok, Gateway} = blockchain_ledger_v1:find_gateway_info(A, Ledger),
            Mode = blockchain_ledger_gateway_v2:mode(Gateway),
            blockchain_ledger_gateway_v2:is_valid_capability(
                    Mode,
                    ?GW_CAPABILITY_POC_CHALLENGEE,
                    Ledger
                )
        end,
        AddrList
    ).

%%%-------------------------------------------------------------------
%% Helpers
%%%-------------------------------------------------------------------
-spec prob_randomness_wt(Vars :: map()) -> float().
prob_randomness_wt(Vars) ->
    maps:get(poc_v5_target_prob_randomness_wt, Vars).

-spec hex_list(Ledger :: blockchain_ledger_v1:ledger(), RandState :: rand:state()) -> {[{h3:h3_index(), pos_integer()}], rand:state()}.
hex_list(Ledger, RandState) ->
    {ok, Count} = blockchain:config(?poc_target_pool_size, Ledger),
    hex_list(Ledger, RandState, Count, []).

hex_list(_Ledger, RandState, 0, Acc) ->
    %% usort so if we selected duplicates they don't get overselected
    {lists:usort(Acc), RandState};
hex_list(Ledger, RandState, Count, Acc) ->
    {ok, Hex, NewRandState} = blockchain_ledger_v1:random_targeting_hex(RandState, Ledger),
    case blockchain_ledger_v1:count_gateways_in_hex(Hex, Ledger) of
        0 ->
            %% this should not happen, but handle it anyway
            hex_list(Ledger, NewRandState, Count, Acc);
        Count ->
            hex_list(Ledger, NewRandState, Count - 1, [{Hex, Count}|Acc])
    end.

-spec choose_zone(
    RandState :: rand:state(),
    HexList :: [h3:h3_index()]
) -> {ok, {h3:h3_index(), rand:state()}} | {error, empty_hex_list}.
choose_zone(_RandState, [] = _HexList) ->
    {error, empty_hex_list};
choose_zone(RandState, HexList) ->
    {HexVal, HexRandState} = rand:uniform_s(RandState),
    case blockchain_utils:icdf_select(HexList, HexVal) of
        {error, zero_weight} ->
            lager:info("choose zone error with zero weight, trying again", []),
            %% retry
            choose_zone(HexRandState, HexList);
        {ok, Hex} ->
            lager:info("choose zone success, found hex ~p", [Hex]),
            {ok, {Hex, HexRandState}}
    end.

limit_addrs(#{?poc_witness_consideration_limit := Limit}, RandState, Witnesses) ->
    blockchain_utils:deterministic_subset(Limit, RandState, Witnesses);
limit_addrs(_Vars, RandState, Witnesses) ->
    {RandState, Witnesses}.
