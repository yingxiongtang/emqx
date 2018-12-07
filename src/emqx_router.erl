%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_router).

-behaviour(gen_server).

-include("emqx.hrl").
-include_lib("ekka/include/ekka.hrl").

%% Mnesia bootstrap
-export([mnesia/1]).

-boot_mnesia({mnesia, [boot]}).
-copy_mnesia({mnesia, [copy]}).

-export([start_link/2]).

%% Route APIs
-export([add_route/1, add_route/2]).
-export([get_routes/1]).
-export([delete_route/1, delete_route/2]).
-export([has_routes/1, match_routes/1, print_routes/1]).
-export([topics/0]).

%% Mode
-export([set_mode/1, get_mode/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-type(destination() :: node() | {binary(), node()}).

-define(ROUTE, emqx_route).

%%------------------------------------------------------------------------------
%% Mnesia bootstrap
%%------------------------------------------------------------------------------

mnesia(boot) ->
    ok = ekka_mnesia:create_table(?ROUTE, [
                {type, bag},
                {ram_copies, [node()]},
                {record_name, route},
                {attributes, record_info(fields, route)},
                {storage_properties, [{ets, [{read_concurrency, true},
                                             {write_concurrency, true}]}]}]);
mnesia(copy) ->
    ok = ekka_mnesia:copy_table(?ROUTE).

%%------------------------------------------------------------------------------
%% Start a router
%%------------------------------------------------------------------------------

-spec(start_link(atom(), pos_integer()) -> emqx_types:startlink_ret()).
start_link(Pool, Id) ->
    Name = emqx_misc:proc_name(?MODULE, Id),
    gen_server:start_link({local, Name}, ?MODULE, [Pool, Id], [{hibernate_after, 1000}]).

%%------------------------------------------------------------------------------
%% Route APIs
%%------------------------------------------------------------------------------

-spec(add_route(emqx_topic:topic() | emqx_types:route()) -> ok | {error, term()}).
add_route(Topic) when is_binary(Topic) ->
    add_route(#route{topic = Topic, dest = node()});
add_route(Route = #route{topic = Topic}) ->
    case get_mode() of
        protected -> do_add_route(Route);
        undefined -> call(pick(Topic), {add_route, Route})
    end.

-spec(add_route(emqx_topic:topic(), destination()) -> ok | {error, term()}).
add_route(Topic, Dest) when is_binary(Topic) ->
    add_route(#route{topic = Topic, dest = Dest}).

%% @private
do_add_route(Route = #route{topic = Topic, dest = Dest}) ->
    case lists:member(Route, get_routes(Topic)) of
        true  -> ok;
        false ->
            ok = emqx_router_helper:monitor(Dest),
            case emqx_topic:wildcard(Topic) of
                true  -> trans(fun add_trie_route/1, [Route]);
                false -> add_direct_route(Route)
            end
    end.

-spec(get_routes(emqx_topic:topic()) -> [emqx_types:route()]).
get_routes(Topic) ->
    ets:lookup(?ROUTE, Topic).

-spec(delete_route(emqx_topic:topic() | emqx_types:route()) -> ok | {error, term()}).
delete_route(Topic) when is_binary(Topic) ->
    delete_route(#route{topic = Topic, dest = node()});
delete_route(Route = #route{topic = Topic}) ->
    case get_mode() of
        protected -> do_delete_route(Route);
        undefined -> call(pick(Topic), {delete_route, Route})
    end.

-spec(delete_route(emqx_topic:topic(), destination()) -> ok | {error, term()}).
delete_route(Topic, Dest) when is_binary(Topic) ->
    delete_route(#route{topic = Topic, dest = Dest}).

%% @private
do_delete_route(Route = #route{topic = Topic}) ->
    case emqx_topic:wildcard(Topic) of
        true  -> trans(fun del_trie_route/1, [Route]);
        false -> del_direct_route(Route)
    end.

-spec(has_routes(emqx_topic:topic()) -> boolean()).
has_routes(Topic) when is_binary(Topic) ->
    ets:member(?ROUTE, Topic).

-spec(topics() -> list(emqx_topic:topic())).
topics() -> mnesia:dirty_all_keys(?ROUTE).

%% @doc Match routes
%% Optimize: routing table will be replicated to all router nodes.
-spec(match_routes(emqx_topic:topic()) -> [emqx_types:route()]).
match_routes(Topic) when is_binary(Topic) ->
    Matched = mnesia:ets(fun emqx_trie:match/1, [Topic]),
    lists:append([get_routes(To) || To <- [Topic | Matched]]).

%% @doc Print routes to a topic
-spec(print_routes(emqx_topic:topic()) -> ok).
print_routes(Topic) ->
    lists:foreach(fun(#route{topic = To, dest = Dest}) ->
                      io:format("~s -> ~s~n", [To, Dest])
                  end, match_routes(Topic)).

-spec(set_mode(protected | atom()) -> any()).
set_mode(Mode) when is_atom(Mode) ->
    put('$router_mode', Mode).

-spec(get_mode() -> protected | undefined | atom()).
get_mode() -> get('$router_mode').

call(Router, Msg) ->
    gen_server:call(Router, Msg, infinity).

pick(Topic) ->
    gproc_pool:pick_worker(router, Topic).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([Pool, Id]) ->
    true = gproc_pool:connect_worker(Pool, {Pool, Id}),
    {ok, #{pool => Pool, id => Id}}.

handle_call({add_route, Route}, _From, State) ->
    {reply, do_add_route(Route), State};

handle_call({delete_route, Route}, _From, State) ->
    {reply, do_delete_route(Route), State};

handle_call(Req, _From, State) ->
    emqx_logger:error("[Router] unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    emqx_logger:error("[Router] unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    emqx_logger:error("[Router] unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #{pool := Pool, id := Id}) ->
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

add_direct_route(Route) ->
    mnesia:async_dirty(fun mnesia:write/3, [?ROUTE, Route, sticky_write]).

add_trie_route(Route = #route{topic = Topic}) ->
    case mnesia:wread({?ROUTE, Topic}) of
        [] -> emqx_trie:insert(Topic);
        _  -> ok
    end,
    mnesia:write(?ROUTE, Route, sticky_write).

del_direct_route(Route) ->
    mnesia:async_dirty(fun mnesia:delete_object/3, [?ROUTE, Route, sticky_write]).

del_trie_route(Route = #route{topic = Topic}) ->
    case mnesia:wread({?ROUTE, Topic}) of
        [Route] -> %% Remove route and trie
                   mnesia:delete_object(?ROUTE, Route, sticky_write),
                   emqx_trie:delete(Topic);
        [_|_]   -> %% Remove route only
                   mnesia:delete_object(?ROUTE, Route, sticky_write);
        []      -> ok
    end.

%% @private
-spec(trans(function(), list(any())) -> ok | {error, term()}).
trans(Fun, Args) ->
    case mnesia:transaction(Fun, Args) of
        {atomic, _}      -> ok;
        {aborted, Error} -> {error, Error}
    end.

