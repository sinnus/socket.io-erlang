-module(socketio_http_misultin).
-behaviour(socketio_http_server).
-export([start_link/1, file/2, respond/2, respond/3, respond/4, parse_post/1, headers/2, chunk/2, stream/2,
         socket/1, get_headers/1, websocket_send/2, ensure_longpolling_request/1]).

start_link(Opts) ->
    Port = proplists:get_value(port, Opts),
    Resource = proplists:get_value(resource, Opts),
    SSL = proplists:get_value(ssl, Opts),
    HttpHandler = proplists:get_value(http_handler, Opts),
    misultin:start_link(create_options(Port, Resource, SSL, HttpHandler)).

file(Request, Filename) ->
    misultin_req:file(Filename, Request).

respond(Request, Code) ->
    misultin_req:respond(Code, Request).

respond(Request, Code, Content) ->
    misultin_req:respond(Code, Content, Request).

respond(Request, Code, Headers, Content) ->
    misultin_req:respond(Code, Headers, Content, Request).

parse_post(Request) ->
    misultin_req:parse_post(Request).

headers(Request, Headers) ->
    misultin_req:stream(head, 200, Headers, Request).

chunk(Request, Chunk) ->
    misultin_req:chunk(Chunk, Request).

stream(Request, Data) ->
    misultin_req:stream(Data, Request).

socket(Request) ->
    get_socket(misultin_req:get(socket, Request)).

get_socket({sslsocket, new_ssl, Pid}) ->
    Pid;
get_socket(Socket) ->
    Socket.

get_headers(Request) ->
    misultin_req:get(headers, Request).

websocket_send(Ws, Data) ->
    misultin_ws:send(Data, Ws).

ensure_longpolling_request(Request) ->
    misultin_req:options([{comet, true}], Request).

%% Internal functions
create_options(Port, Resource, undefined, HttpHandler) ->
    [{port, Port},
     {name, false},
     {loop, fun (Req) -> handle_http(Req, Resource, HttpHandler) end},
     {ws_loop, fun (Ws) -> handle_websocket(Resource, Ws) end},
     {ws_autoexit, false}];
create_options(Port, Resource, SSL, HttpHandler) ->
    Certfile = proplists:get_value(certfile, SSL),
    Keyfile = proplists:get_value(keyfile, SSL),
    Password = proplists:get_value(password, SSL),
    [{port, Port},
     {name, false},
     {loop, fun (Req) -> handle_http(Req, Resource, HttpHandler) end},
     {ws_loop, fun (Ws) -> handle_websocket(Resource, Ws) end},
     {ws_autoexit, false},
     {ssl, [{certfile, Certfile},
	    {keyfile, Keyfile},
	    {password, Password}
	   ]}].

handle_http(Req, Resource, HttpHandler) ->
    Path = misultin_req:resource([urldecode], Req),
    dispatch_http({request, misultin_req:get(method, Req), lists:reverse(Path), Req}, Resource, HttpHandler).

handle_websocket(Resource, Ws) ->
    WsPath = misultin_ws:get(path, Ws),
    WsResource = string:tokens(WsPath,"/"),
    handle_websocket_1(Resource, lists:reverse(WsResource), Ws).

handle_websocket_1(Resource, ["flashsocket"|Resource], Ws) ->
    handle_websocket_1(Resource, ["websocket"|Resource], Ws);

handle_websocket_1(Resource, ["websocket"|Resource], Ws) ->
    {SessionID, Pid} = socketio_manager:create_new_session({websocket, Ws}, socketio_transport_websocket),
    handle_websocket(Ws, SessionID, Pid);
handle_websocket_1(_Resource, _WsResource, _Ws) ->
    ignore. %% FIXME: pass it through to the end user?

handle_websocket(Ws, SessionID, Pid) ->
    receive
        {browser, Data} ->
            gen_server:call(Pid, {websocket, Data, Ws}),
            handle_websocket(Ws, SessionID, Pid);
        closed ->
            gen_server:call(Pid, stop);
        _Ignore ->
            handle_websocket(Ws, SessionID, Pid)
    end.

%%%%%%%%%%%%%%%%%%%%
%% Http distpatchers
%%%%%%%%%%%%%%%%%%%%
dispatch_http({request, 'GET', ["socket.io.js"|Resource], Req}, Resource, _HttpHandler) ->
    file(Req, filename:join([filename:dirname(code:which(?MODULE)), "..", "priv", "Socket.IO", "socket.io.js"]));

dispatch_http({request, 'GET', ["WebSocketMain.swf", "web-socket-js", "vendor", "lib"|Resource], Req}, Resource, _HttpHandler) ->
    file(Req, filename:join([filename:dirname(code:which(?MODULE)), "..", "priv", "Socket.IO", "lib", "vendor", "web-socket-js", "WebSocketMain.swf"]));

%% New XHR Polling request
dispatch_http({request, 'GET', [_Random, "xhr-polling"|Resource], Req}, Resource, _HttpHandler) ->
    socketio_manager:create_new_session({'xhr-polling', Req}, socketio_transport_polling);

%% Returning XHR Polling
dispatch_http({request, 'GET', [_Random, SessionId, "xhr-polling"|Resource], Req}, Resource, _HttpHandler) ->
    case socketio_manager:get_client_pid(SessionId) of
        undefined ->
            respond(Req, 404, "");
        Pid ->
            gen_server:call(Pid, {'xhr-polling', polling_request, Req}, infinity)
    end;

%% Incoming XHR Polling data
dispatch_http({request, 'POST', ["send", SessionId, "xhr-polling"|Resource], Req}, Resource, _HttpHandler) ->
    case socketio_manager:get_client_pid(SessionId) of
        undefined ->
            respond(Req, 404, "");
        Pid ->
            gen_server:call(Pid, {'xhr-polling', data, Req})
    end;

%% New JSONP Polling request
dispatch_http({request, 'GET', [Index, _Random, "jsonp-polling"|Resource], Req }, Resource, _HttpHandler) ->
    socketio_manager:create_new_session({'jsonp-polling', {Req, Index}}, socketio_transport_polling);

%% Returning JSONP Polling
dispatch_http({request, 'GET', [Index, _Random, SessionId, "jsonp-polling"|Resource], Req }, Resource, _HttpHandler) ->
    case socketio_manager:get_client_pid(SessionId) of
        undefined ->
            respond(Req, 404, "");
        Pid ->
            gen_server:call(Pid, {'jsonp-polling', polling_request, {Req, Index}}, infinity)
    end;

%% Incoming JSONP Polling data
dispatch_http({request, 'POST', [_Index, _Random, SessionId, "jsonp-polling"|Resource], Req }, Resource, _HttpHandler) ->
    case socketio_manager:get_client_pid(SessionId) of
        undefined ->
            respond(Req, 404, "");
        Pid ->
            gen_server:call(Pid, {'jsonp-polling', data, Req})
    end;

%% New XHR Multipart request
dispatch_http({request, 'GET', ["xhr-multipart"|Resource], Req }, Resource, _HttpHandler) ->
    {_, Pid1} = socketio_manager:create_new_session({'xhr-multipart', {Req, self()}}, socketio_transport_xhr_multipart),
    Ref = erlang:monitor(process, Pid1),
    receive
        {'DOWN', Ref, process, _, _} -> 
            ok;
        Ignore ->
            error_logger:warning_msg("Ignore: ~p~n", [Ignore])
    end;

%% Incoming XHR Multipart data
dispatch_http({request, 'POST', ["send", SessionId, "xhr-multipart"|Resource], Req }, Resource, _HttpHandler) ->
    case socketio_manager:get_client_pid(SessionId) of
        undefined ->
            respond(Req, 404, "");
        Pid ->
            gen_server:call(Pid, {'xhr-multipart', data, Req})
    end;

%% New htmlfile request
dispatch_http({request, 'GET', [_Random, "htmlfile"|Resource], Req }, Resource, _HttpHandler) ->
    {_, Pid1} = socketio_manager:create_new_session({'htmlfile', {Req, self()}}, socketio_transport_htmlfile),
    Ref = erlang:monitor(process, Pid1),
    receive
        {'DOWN', Ref, process, _, _} -> 
            ok;
        Ignore ->
            error_logger:warning_msg("Ignore: ~p~n", [Ignore])
    end;

%% Incoming htmlfile data
dispatch_http({request, 'POST', ["send", SessionId, "htmlfile"|Resource], Req }, Resource, _HttpHandler) ->
    case socketio_manager:get_client_pid(SessionId) of
        undefined ->
            respond(Req, 404, "");
        Pid ->
            gen_server:call(Pid, {'htmlfile', data, Req})
    end;

dispatch_http({request, Method, Path, Req}, _Resource, HttpHandler) ->
    HttpHandler:handle_request(Method, lists:reverse(Path), Req).
