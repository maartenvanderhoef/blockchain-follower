%%%-------------------------------------------------------------------
%% @doc blockchain_follower top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(bf_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [I]
}).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one,
                 intensity => 0,
                 period => 1},
    SeedNodes =
        case application:get_env(blockchain, seed_nodes) of
            {ok, ""} -> [];
            {ok, Seeds} -> string:split(Seeds, ",", all);
            _ -> []
        end,

    BaseDir = application:get_env(blockchain, base_dir, "data"),

    SwarmKey = filename:join([BaseDir, "blockchain_follower", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    {PublicKey, ECDHFun, SigFun} =
        case libp2p_crypto:load_keys(SwarmKey) of
            {ok, #{secret := PrivKey0, public := PubKey}} ->
                {PubKey,
                 libp2p_crypto:mk_ecdh_fun(PrivKey0),
                 libp2p_crypto:mk_sig_fun(PrivKey0)};
            {error, enoent} ->
                KeyMap = #{secret := PrivKey0, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
                ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
                {PubKey,
                 libp2p_crypto:mk_ecdh_fun(PrivKey0),
                 libp2p_crypto:mk_sig_fun(PrivKey0)}
        end,

    SeedNodeDNS = application:get_env(blockchain, seed_node_dns, []),
    SeedAddresses = string:tokens(lists:flatten([string:prefix(X, "blockchain-seed-nodes=")
                                                 || [X] <- inet_res:lookup(SeedNodeDNS, in, txt),
                                                    string:prefix(X, "blockchain-seed-nodes=") /= nomatch]), ","),
    Port = application:get_env(blockchain, port, 0),
    MaxInboundConnections = application:get_env(blockchain, max_inbound_connections, 10),

    BlockchainOpts = [
        {key, {PublicKey, SigFun, ECDHFun}},
        {seed_nodes, SeedNodes ++ SeedAddresses},
        {max_inbound_connections, MaxInboundConnections},
        {port, Port},
        {update_dir, "update"},
        {base_dir, BaseDir}
    ],

    ChildSpecs = [
                  ?SUP(blockchain_sup, [BlockchainOpts]),
                  ?WORKER(bf_follower, [])
                 ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
