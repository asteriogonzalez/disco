
-module(ddfs_tag).
-behaviour(gen_server).

-include("config.hrl").

-export([start/1, init/1, handle_call/3, handle_cast/2,
        handle_info/2, terminate/2, code_change/3]).

-record(state, {tag, data, timeout, replicas, url_cache}).

% THOUGHT: Eventually we want to partition tag keyspace instead
% of using a single global keyspace. This can be done relatively 
% easily with consistent hashing: Each tag has a set of nodes 
% (partition) which it operates on. If tag can't be found in its
% partition (due to addition of many new nodes, for instance),
% partition to be searched can be increased incrementally until
% the tag is found.
% 
% Correspondingly GC'ing must ensure that K replicas for a tag
% are found within its partition rather than globally.

start(TagName) ->
    gen_server:start(ddfs_tag, TagName, []).

init(TagName) ->
    put(min_tagk, list_to_integer(disco:get_setting("DDFS_TAG_MIN_REPLICAS"))),
    put(tagk, list_to_integer(disco:get_setting("DDFS_TAG_REPLICAS"))),

    {ok, #state{tag = TagName,
                data = false,
                replicas = false,
                url_cache = false,
                timeout = ?TAG_EXPIRES}}.

% We don't want to cache requests made by garbage collector
handle_cast({gc_get, ReplyTo}, #state{data = false} = S) ->
    handle_cast({gc_get0, ReplyTo}, S#state{timeout = 100});

% On the other hand, if tag is already cached, GC'ing should
% not trash it
handle_cast({gc_get, ReplyTo}, S) ->
    handle_cast({gc_get0, ReplyTo}, S);

handle_cast(M, #state{data = false} = S) ->
    {Data, Replicas, Timeout} =
        case is_tag_deleted(S#state.tag) of
            true ->
                {deleted, false, ?TAG_EXPIRES_ONERROR};
            false ->
                case get_tagdata(S#state.tag) of
                    {ok, TagData, Repl} ->
                        {TagData, Repl, S#state.timeout};
                    E ->
                        {E, false, ?TAG_EXPIRES_ONERROR}
                end;
            E ->
                {E, false, ?TAG_EXPIRES_ONERROR}
        end,
    handle_cast(M, S#state{
                data = Data,
                replicas = Replicas,
                timeout = lists:min([Timeout, S#state.timeout])});

handle_cast({get, ReplyTo}, S) ->
    gen_server:reply(ReplyTo, S#state.data),
    {noreply, S, S#state.timeout};

handle_cast({_, ReplyTo}, #state{data = {error, _}} = S) ->
    handle_cast({get, ReplyTo}, S);

handle_cast({gc_get0, ReplyTo}, S) ->
    gen_server:reply(ReplyTo, {S#state.data, S#state.replicas}),
    {noreply, S, S#state.timeout};

handle_cast({{update, Urls}, ReplyTo}, #state{data = notfound} = S) ->
    handle_cast({{put, Urls}, ReplyTo}, S);

handle_cast({{update, Urls}, ReplyTo}, #state{data = deleted} = S) ->
    handle_cast({{put, Urls}, ReplyTo}, S);

handle_cast({{update, Urls}, ReplyTo}, #state{data = D} = S) ->
    % XXX: decompress data here!
    case parse_tagurls(D) of
        {error, _} = E ->
            gen_server:reply(ReplyTo, E),
            {noreply, S, S#state.timeout};
        {ok, OldUrls} ->
            case validate_urls(Urls) of
                true ->
                    handle_cast({{put, Urls ++ OldUrls}, ReplyTo}, S);
                false ->
                    gen_server:reply(ReplyTo, {error, invalid_url_object}),
                    {noreply, S, S#state.timeout}
            end
    end;

handle_cast({{put, Urls}, ReplyTo}, S) ->
    case put_transaction(validate_urls(Urls), Urls, S) of
        {ok, DestNodes, DestUrls, TagData} ->
            if S#state.data == deleted ->
                {ok, _} = remove_from_deleted(S#state.tag);
            true -> ok
            end,
            gen_server:reply(ReplyTo, {ok, DestUrls}),
            S1 = S#state{data = TagData, replicas = DestNodes},
            if S#state.url_cache == false ->
                {noreply, S1, S#state.timeout};
            true ->
                {noreply, S1#state{url_cache = lists:usort(Urls)},
                    S#state.timeout}
            end;
        {error, _} = E ->
            gen_server:reply(ReplyTo, E),
            {noreply, S, S#state.timeout}
    end;

% Special operations for the +deleted metatag

handle_cast({get_urls, ReplyTo}, #state{data = notfound} = S) ->
    gen_server:reply(ReplyTo, {ok, []}),
    {noreply, S, S#state.timeout};

handle_cast({get_urls, _} = M, #state{url_cache = false} = S) ->
    {ok, Urls} = parse_tagurls(S#state.data),
    handle_cast(M, S#state{url_cache = lists:usort(Urls)});

handle_cast({get_urls, ReplyTo}, #state{url_cache = Urls} = S) ->
    gen_server:reply(ReplyTo, {ok, Urls}),
    {noreply, S, S#state.timeout};

handle_cast({{remove, Urls}, ReplyTo}, S) ->
    {ok, OldUrls} =
        if S#state.url_cache == false ->
            parse_tagurls(S#state.data);
        true ->
            {ok, S#state.url_cache}
        end,
    NewUrls = [U || [_|_] = U <- [R -- Urls || R <- OldUrls]],
    handle_cast({{put, NewUrls}, ReplyTo}, S);

handle_cast({die, _}, S) ->
    {stop, normal, S}.

handle_call(_, _, S) -> {reply, ok, S}.

handle_info(timeout, S) ->
    {stop, normal, S}.

% callback stubs
terminate(_Reason, _State) -> {}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

get_tagdata(Tag) ->
    {ok, Nodes} = gen_server:call(ddfs_master, get_nodes),
    {Replies, Failed} = gen_server:multi_call(Nodes, ddfs_node,
        {get_tag_timestamp, Tag}, ?NODE_TIMEOUT),
    TagMinK = get(min_tagk),
    case [{TagNfo, Node} || {Node, {ok, TagNfo}} <- Replies] of
        _ when length(Failed) >= TagMinK ->
            {error, too_many_failed_nodes};
        [] ->
            notfound;
        L ->
            {{Time, _} = T, _} = lists:max(L),
            Replicas = [N || {{X, _}, N} <- L, X == Time],
            SrcNode = ddfs_util:choose_random(Replicas),
            TagName = ddfs_util:pack_objname(Tag, Time),
            case catch gen_server:call({ddfs_node, SrcNode},
                    {get_tag_data, TagName, T}, ?NODE_TIMEOUT) of
                {ok, Data} ->
                    {ok, Data, Replicas};
                {'EXIT', timeout} ->
                    {error, timeout};
                E ->
                    E
            end
    end.

validate_urls(Urls) ->
    [] == (catch lists:flatten([[1 || X <- L, not is_binary(X)] || L <- Urls])).

parse_tagurls(TagData) ->
    case catch mochijson2:decode(TagData) of
        {'EXIT', _} ->
            {error, corrupted_json};
        {struct, Body} ->
            case lists:keysearch(<<"urls">>, 1, Body) of
                {value, {_, Urls}} ->
                    {ok, Urls};
                _ ->
                    {error, invalid_object}
            end;
        _ ->
            {error, invalid_json}
    end.

% Put transaction:
% 1. choose nodes
% 2. multicall nodes, send TagData -> receive temporary file names
% 3. if failures -> retry with other nodes
% 4. if all nodes fail before tagk replicas are written, fail
% 5. multicall with temp file names, rename
% 6. if all fail, fail
% 7. if at least one multicall succeeds, return updated tagdata, desturls

put_transaction(false, _, _) -> {error, invalid_url_object};
put_transaction(true, Urls, S) ->
    % XXX: compress data here!
    TagName = ddfs_util:pack_objname(S#state.tag, now()),
    TagData = list_to_binary(mochijson2:encode({struct,
                [
                    {<<"id">>, TagName},
                    {<<"version">>, 1},
                    {<<"urls">>, Urls},
                    {<<"last-modified">>, ddfs_util:format_timestamp()} 
                ]})),
    put_distribute({TagName, TagData}).

put_distribute(Msg) ->
    case put_distribute(Msg, get(tagk), [], []) of
        {ok, TagVol} -> put_commit(Msg, TagVol);
        {error, _} = E -> E
    end.

put_distribute(_, K, OkNodes, _) when K == length(OkNodes) ->
    {ok, OkNodes};

put_distribute(Msg, K, OkNodes, Exclude) ->
    TagMinK = get(min_tagk),
    K0 = K - length(OkNodes),
    {ok, Nodes} = gen_server:call(ddfs_master, {choose_nodes, K0, Exclude}),
    if Nodes =:= [], length(OkNodes) < TagMinK ->
        {error, replication_failed};
    Nodes =:= [] ->
        {ok, OkNodes};
    true ->
        {Replies, Failed} = gen_server:multi_call(Nodes,
                ddfs_node, {put_tag_data, Msg}, ?NODE_TIMEOUT),
        put_distribute(Msg, K,
            OkNodes ++ [{N, Vol} || {N, {ok, Vol}} <- Replies],
            Exclude ++ [N || {N, _} <- Replies] ++ Failed)
    end.

put_commit({TagName, TagData}, TagVol) ->
    {Nodes, _} = lists:unzip(TagVol),
    {Ok, _} = gen_server:multi_call(Nodes, ddfs_node,
                {put_tag_commit, TagName, TagVol}, ?NODE_TIMEOUT),
    case [U || {_, {ok, U}} <- Ok] of
        [] ->
            {error, commit_failed};
        Urls ->
            {ok, Nodes, Urls, TagData}
    end.

is_tag_deleted(<<"+deleted">>) -> false;
is_tag_deleted(Tag) ->
    case gen_server:call(ddfs_master,
            {tag, get_urls, <<"+deleted">>}, ?NODEOP_TIMEOUT) of
        {ok, Deleted} ->
            lists:member(Tag, [T || [<<"tag://", T/binary>>] <- Deleted]);
        E -> E
    end.

remove_from_deleted(Tag) ->
    gen_server:call(ddfs_master, {tag, {remove, [<<"tag://", Tag/binary>>]},
        <<"+deleted">>}, ?NODEOP_TIMEOUT).
    


    
    
    


                    

