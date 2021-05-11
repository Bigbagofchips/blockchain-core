-module(blockchain_implicit_burn_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("blockchain_vars.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-export([
         enable_implicit_burn_test/1,
         disabled_implicit_burn_test/1
        ]).

all() ->
    [
     enable_implicit_burn_test,
     disabled_implicit_burn_test
    ].

-define(MAX_PAYMENTS, 20).

%% we use this to fund the accounts and mock some proper price for HNT ($15)
-define(MULTIPLIER, 10000000).

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    Config0 = blockchain_ct_utils:init_base_dir_config(?MODULE, TestCase, Config),
    Balance = 5000 * ?MULTIPLIER,
    {ok, Sup, {PrivKey, PubKey}, Opts} = test_utils:init(?config(base_dir, Config0)),

    ExtraVars = extra_vars(TestCase),

    {ok, GenesisMembers, _GenesisBlock, ConsensusMembers, Keys} =
        test_utils:init_chain(Balance, {PrivKey, PubKey}, true, ExtraVars),

    Chain = blockchain_worker:blockchain(),
    Swarm = blockchain_swarm:swarm(),
    N = length(ConsensusMembers),

    % Check ledger to make sure everyone has the right balance
    Ledger = blockchain:ledger(Chain),
    Entries = blockchain_ledger_v1:entries(Ledger),
    _ = lists:foreach(fun(Entry) ->
                              Balance = blockchain_ledger_entry_v1:balance(Entry),
                              0 = blockchain_ledger_entry_v1:nonce(Entry)
                      end, maps:values(Entries)),

    meck:new(blockchain_ledger_v1, [passthrough]),

    [
     {balance, Balance},
     {sup, Sup},
     {pubkey, PubKey},
     {privkey, PrivKey},
     {opts, Opts},
     {chain, Chain},
     {swarm, Swarm},
     {n, N},
     {consensus_members, ConsensusMembers},
     {genesis_members, GenesisMembers},
     Keys
     | Config0
    ].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------

end_per_testcase(_, Config) ->
    meck:unload(blockchain_ledger_v1),
    Sup = ?config(sup, Config),
    % Make sure blockchain saved on file = in memory
    case erlang:is_process_alive(Sup) of
        true ->
            true = erlang:exit(Sup, normal),
            ok = test_utils:wait_until(fun() -> false =:= erlang:is_process_alive(Sup) end);
        false ->
            ok
    end,
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

enable_implicit_burn_test(Config) ->
    BaseDir = ?config(base_dir, Config),
    ConsensusMembers = ?config(consensus_members, Config),
    BaseDir = ?config(base_dir, Config),
    Chain = ?config(chain, Config),
    Ledger = blockchain:ledger(Chain),

    meck:expect(
        blockchain_ledger_v1,
        current_oracle_price,
        fun(_) ->
                {ok, 15 * ?MULTIPLIER}
        end
    ),

    %% Set env to store implicit burn %%
    ok = application:set_env(blockchain, store_implicit_burns, true),

    %% Test a payment transaction, add a block and check balances
    [_, {Payer, {_, PayerPrivKey, _}}|_] = ConsensusMembers,

    %% Create a payment to a single payee
    Recipient = blockchain_swarm:pubkey_bin(),
    Amount = 2500,
    Payment1 = blockchain_payment_v2:new(Recipient, Amount),

    Tx0 = blockchain_txn_payment_v2:new(Payer, [Payment1], 1),
    Fee = blockchain_txn_payment_v2:calculate_fee(Tx0, Chain),
    Tx1 = blockchain_txn_payment_v2:fee(Tx0, Fee),
    SigFun = libp2p_crypto:mk_sig_fun(PayerPrivKey),
    SignedTx = blockchain_txn_payment_v2:sign(Tx1, SigFun),

    ct:pal("~s", [blockchain_txn:print(SignedTx)]),

    {ok, Block} = test_utils:create_block(ConsensusMembers, [SignedTx]),
    _ = blockchain_gossip_handler:add_block(Block, Chain, self(), blockchain_swarm:swarm()),

    TxHash = blockchain_txn:hash(SignedTx),

    %% Check that there is an implicit burn
    {ok, ImplicitBurn} = blockchain:get_implicit_burn(TxHash, Chain),
    ct:pal("implicit burn: ~p", [ImplicitBurn]),
    ct:pal("implicit burn fee: ~p", [blockchain_implicit_burn:fee(ImplicitBurn)]),
    %% Check that the fee in implicit burn is as expected after conversion to
    %% equivalent hnt depending on the mockoracle price
    {ok, FeeInHNT} = blockchain_ledger_v1:dc_to_hnt(Fee, Ledger),
    true = FeeInHNT == blockchain_implicit_burn:fee(ImplicitBurn),

    ok.

disabled_implicit_burn_test(Config) ->
    BaseDir = ?config(base_dir, Config),
    ConsensusMembers = ?config(consensus_members, Config),
    BaseDir = ?config(base_dir, Config),
    Chain = ?config(chain, Config),

    %% Set env to store implicit burn %%
    ok = application:set_env(blockchain, store_implicit_burns, false),

    %% Test a payment transaction, add a block and check balances
    [_, {Payer, {_, PayerPrivKey, _}}|_] = ConsensusMembers,

    %% Create a payment to a single payee
    Recipient = blockchain_swarm:pubkey_bin(),
    Amount = 2500,
    Payment1 = blockchain_payment_v2:new(Recipient, Amount),

    Tx0 = blockchain_txn_payment_v2:new(Payer, [Payment1], 1),
    Fee = blockchain_txn_payment_v2:calculate_fee(Tx0, Chain),
    Tx1 = blockchain_txn_payment_v2:fee(Tx0, Fee),
    SigFun = libp2p_crypto:mk_sig_fun(PayerPrivKey),
    SignedTx = blockchain_txn_payment_v2:sign(Tx1, SigFun),

    ct:pal("~s", [blockchain_txn:print(SignedTx)]),

    {ok, Block} = test_utils:create_block(ConsensusMembers, [SignedTx]),
    _ = blockchain_gossip_handler:add_block(Block, Chain, self(), blockchain_swarm:swarm()),

    TxHash = blockchain_txn:hash(SignedTx),

    %% Check that there is NO implicit burn
    {error, not_found} = blockchain:get_implicit_burn(TxHash, Chain),
    ct:pal("Confirmed that implicit burn has not been stored for ~p", [TxHash]),
    ok.

%%--------------------------------------------------------------------
%% HELPERS
%%--------------------------------------------------------------------
extra_vars(_) ->
    #{?txn_fees => true, ?max_payments => ?MAX_PAYMENTS, ?allow_zero_amount => false}.
