-module(nova_stream_h).
-behavior(cowboy_stream).

-export([
         init/3,
         data/4,
         info/3,
         terminate/3,
         early_error/5
        ]).

-include_lib("nova/include/nova.hrl").

-record(state, {
                next :: any(),
                req
               }).
-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
          -> {cowboy_stream:commands(), #state{}}.
init(StreamID, Req, Opts) ->
    {Commands, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {Commands, #state{req = Req, next = Next}}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
          -> {cowboy_stream:commands(), State} when State::#state{}.
data(StreamID, IsFin, Data, State = #state{next = Next}) ->
    {Commands, Next0} = cowboy_stream:data(StreamID, IsFin, Data, Next),
    {Commands, State#state{next = Next0}}.

-spec info(cowboy_stream:streamid(), any(), State)
	-> {cowboy_stream:commands(), State} when State::#state{}.
info(StreamID, {response, Code, Headers, _Body} = Info, State = #state{next = Next, req = Req})
  when is_integer(Code) ->
    case nova_router:status_page(Code, Req) of
        {ok, StatusCode, StatusHeaders, StatusBody, _} ->
            {[{error_response, StatusCode, StatusHeaders, StatusBody},
              stop], State};
        Ret ->
            {Commands, Next0} = cowboy_stream:info(StreamID, Info, Next),
            {Commands, State#state{next = Next0}}
    end;
info(StreamID, Info, State = #state{next = Next}) ->
    {Commands, Next0} = cowboy_stream:info(StreamID, Info, Next),
    {Commands, State#state{next = Next0}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), #state{}) -> any().
terminate(StreamID, Reason, #state{next = Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
                  cowboy_stream:partial_req(), Resp, cowboy:opts())
                 -> Resp
                        when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, {_, Status, Headers, _} = Resp, Opts) ->
    case nova_router:status_page(Status, PartialReq) of
        {ok, Req0} ->
            cowboy_stream:early_error(StreamID, Reason, PartialReq, {response, Status, Headers, Req0}, Opts);
        _ ->
            cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts)
    end.