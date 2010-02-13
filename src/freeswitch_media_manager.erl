%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at fusedsolutions dot com>
%%

%% @doc The controlling module for connection CPX to a freeswitch installation.  There are 2 primary requirements for this work:  
%% the freeswitch installaction must have mod_erlang installed and active, and the freeswitch dialplan must add the following
%% variables to the call data:
%% <dl>
%% <dt>queue</dt><dd>The name of the queue as entered into the queue_manager</dd>
%% <dt>brand</dt><dd>As the combined brand id</dd>
%% </dl>
%% Primary job of this module is to listen to freeswitch for events, and shove those events to the appriate child process.
%% @see freeswitch_media

-module(freeswitch_media_manager).
-author("Micah").

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("queue.hrl").
-include("call.hrl").
-include("agent.hrl").

-define(TIMEOUT, 10000).
-define(EMPTYRESPONSE, "<document type=\"freeswitch/xml\"></document>").
-define(NOTFOUNDRESPONSE,
"<document type=\"freeswitch/xml\">
	<section name=\"result\">
		<result status=\"not found\" />
	</section>
</document>").

-define(DIALUSERRESPONSE,
"<document type=\"freeswitch/xml\">
	<section name=\"directory\">
		<domain name=\"~s\">
			<user id=\"~s\">
				<params>
					<param name=\"dial-string\" value=\"~s\"/>
				</params>
			</user>
		</domain>
	</section>
</document>").

-define(REGISTERRESPONSE,
"<document type=\"freeswitch/xml\">
	<section name=\"directory\">
		<domain name=\"~s\">
			<user id=\"~s\">
				<params>
					<param name=\"a1-hash\" value=\"~s\"/>
				</params>
			</user>
		</domain>
	</section>
</document>").

-define(USERRESPONSE,
"<document type=\"freeswitch/xml\">
	<section name=\"directory\">
		<domain name=\"~s\">
			<user id=\"~s\">
			</user>
		</domain>
	</section>
</document>").



%% API
-export([
	start_link/2, 
	start/2, 
	stop/0,
	get_handler/1,
	notify/2,
	make_outbound_call/3,
	record_outage/3,
	fetch_domain_user/2,
	new_voicemail/5,
	ring_agent/4,
	get_media/1,
	do_dial_string/3
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {
	nodename :: atom(),
	freeswitch_up = false :: boolean(),
	call_dict = dict:new() :: dict(),
	dialstring = "" :: string(),
	eventserver :: pid() | 'undefined',
	xmlserver :: pid() | 'undefined'
	}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

% watched calls structure:
% callid, pid of gen_server handling it

% notes for tomorrow:  set up a process per call id to watch/process that call id

%%====================================================================
%% API
%%====================================================================

%% @doc Start the media manager unlinked to the parant process with C node `node() Nodemane' 
%% and `[{atom(), term()] Options'.
%% <ul>
%% <li>`domain :: string()'</li>
%% <li>`dialstring :: string()'</li>
%% </ul>
-spec(start/2 :: (Nodename :: atom(), Options :: [any()]) -> {'ok', pid()}).
start(Nodename, [Head | _Tail] = Options) when is_tuple(Head) ->
	gen_server:start({local, ?MODULE}, ?MODULE, [Nodename, Options], []).
	
%% @doc Start the media manager unlinked to the parent process.  `Nodename' is the name of the C node for mod_erlang in freeswitch; 
%% `Domain' is the domain to ring to sip agents.
%% @clear
% Domain is there to help ring agents.
%start(Nodename) -> 
%	gen_server:start({local, ?MODULE}, ?MODULE, [Nodename, []], []).
	
%% @doc Start the media manager linked to the parant process with C node `node() Nodemane' 
%% and `[{atom(), term()] Options'.
%% <ul>
%% <li>`domain :: string()'</li>
%% <li>`dialstring :: string()'</li>
%% </ul>
-spec(start_link/2 :: (Nodename :: atom(), Options :: [any()]) -> {'ok', pid()}).
start_link(Nodename, [Head | _Tail] = Options) when is_tuple(Head) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [Nodename, Options], []).

%% @doc Start the media manager linked to the parent process.  `Nodename' is the name of the C node for mod_erlang in freeswitch; 
%% `Domain' is the domain to ring to sip agents.
%% @clear
%start_link(Nodename) ->
%    gen_server:start_link({local, ?MODULE}, ?MODULE, [Nodename, []], []).

%% @doc returns {`ok', pid()} if there is a freeswitch media process handling the given `UUID'.
-spec(get_handler/1 :: (UUID :: string()) -> {'ok', pid()} | 'noexists').
get_handler(UUID) -> 
	gen_server:call(?MODULE, {get_handler, UUID}).

-spec(notify/2 :: (UUID :: string(), Pid :: pid()) -> 'ok').
notify(UUID, Pid) ->
	gen_server:cast(?MODULE, {notify, UUID, Pid}).

-spec(make_outbound_call/3 :: (Client :: any(), AgentPid :: pid(), AgentRec :: #agent{}) -> {'ok', pid()} | {'error', any()}).
make_outbound_call(Client, AgentPid, AgentRec) ->
	gen_server:call(?MODULE, {make_outbound_call, Client, AgentPid, AgentRec}).

record_outage(Client, AgentPid, AgentRec) ->
	gen_server:call(?MODULE, {record_outage, Client, AgentPid, AgentRec}).

-spec(new_voicemail/5 :: (UUID :: string(), File :: string(), Queue :: string(), Priority :: pos_integer(), Client :: #client{} | string()) -> 'ok').
new_voicemail(UUID, File, Queue, Priority, Client) ->
	gen_server:cast(?MODULE, {new_voicemail, UUID, File, Queue, Priority, Client}).

-spec(stop/0 :: () -> 'ok').
stop() ->
	gen_server:call(?MODULE, stop).

%% @doc Just blindly start an agent's phone ringing, set to hangup on pickup.
%% Yes, this is a prank call function.
-spec(ring_agent/4 :: (AgentPid :: pid(), Arec :: #agent{}, Call :: #call{}, Timeout :: pos_integer()) -> {'ok', pid()} | {'error', any()}).
ring_agent(AgentPid, Arec, Call, Timeout) ->
	gen_server:call(?MODULE, {ring_agent, AgentPid, Arec, Call, Timeout}).

-spec(get_media/1 :: (MediaKey :: pid() | string()) -> {string(), pid()} | 'none').
get_media(MediaKey) ->
	gen_server:call(?MODULE, {get_media, MediaKey}).

-spec(do_dial_string/3 :: (DialString :: string(), Destination :: string(), Options :: [string()]) -> string()).
do_dial_string(DialString, Destination, []) ->
	re:replace(DialString, "\\$1", Destination, [{return, list}]);
do_dial_string([${ | _] = DialString, Destination, Options) ->
	% Dialstring begins with a {} block.
	D1 = re:replace(DialString, "\\$1", Destination, [{return, list}]),
	re:replace(D1, "^{", "{" ++ string:join(Options, ",") ++ ",", [{return, list}]);
do_dial_string(DialString, Destination, Options) ->
	D1 = re:replace(DialString, "\\$1", Destination, [{return, list}]),
	"{" ++ string:join(Options, ",") ++ "}" ++ D1.

%%====================================================================
%% gen_server callbacks
%%====================================================================
%% @private
init([Nodename, Options]) -> 
	?DEBUG("starting...", []),
	process_flag(trap_exit, true),
	DialString = proplists:get_value(dialstring, Options, ""),
	monitor_node(Nodename, true),
	{Listenpid, DomainPid} = case net_adm:ping(Nodename) of
		pong ->
			Lpid = start_listener(Nodename),
			freeswitch:event(Nodename, ['CHANNEL_DESTROY']),
			{ok, Pid} = freeswitch:start_fetch_handler(Nodename, directory, ?MODULE, fetch_domain_user, [{dialstring, DialString}]),
			link(Pid),
			{Lpid, Pid};
		_ ->
			{undefined, undefined}
	end,
	{ok, #state{nodename=Nodename, dialstring = DialString, eventserver = Listenpid, xmlserver = DomainPid, freeswitch_up = true}}.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
%% @private

handle_call({make_outbound_call, Client, AgentPid, AgentRec}, _From, #state{nodename = Node, dialstring = DS, freeswitch_up = FS} = State) when FS == true ->
	{ok, Pid} = freeswitch_outbound:start(Node, AgentRec, AgentPid, Client, DS, 30),
	link(Pid),
	{reply, {ok, Pid}, State};
handle_call({make_outbound_call, _Client, _AgentPid, _AgentRec}, _From, State) -> % freeswitch is down
	{reply, {error, noconnection}, State};
handle_call({record_outage, Client, AgentPid, AgentRec}, _From, #state{nodename = Node, freeswitch_up = FS} = State) when FS == true ->
	Recording = "/tmp/"++Client++"/problem.wav",
	case filelib:ensure_dir(Recording) of
		ok ->
			F = fun(UUID) ->
					fun(ok, _Reply) ->
							freeswitch:api(State#state.nodename, uuid_transfer, UUID ++ " 'gentones:%(500\\,0\\,500),sleep:600,record:/tmp/"++Client++"/problem.wav' inline");
						(error, Reply) ->
							?WARNING("originate failed: ~p", [Reply]),
							ok
					end
			end,
			case freeswitch_ring:start(Node, AgentRec, AgentPid, #call{id=none, source=none}, 30, F, [no_oncall_on_bridge]) of
				{ok, _Pid} ->
					{reply, ok, State};
				{error, Reason} ->
					{reply, {error, Reason}, State}
			end;
		{error, Reason} ->
			{reply, {error, Reason}, State}
	end;
handle_call({record_outage, _Client, _AgentPid, _AgentRec}, _From, State) -> % freeswitch is down
	{reply, {error, noconnection}, State};
handle_call({get_handler, UUID}, _From, #state{call_dict = Dict} = State) ->
	case dict:find(UUID, Dict) of
		error -> 
			{reply, noexists, State};
		{ok, Pid} -> 
			{reply, Pid, State}
	end;
handle_call(stop, _From, State) ->
	?NOTICE("Normal termination", []),
	{stop, normal, ok, State};
handle_call({ring_agent, AgentPid, Arec, Call, Timeout}, _From, #state{nodename = Node} = State) ->
	case State#state.freeswitch_up of
		true ->
			Fun = fun(_) ->
				fun(_, _) -> ok end
			end,
			Out = freeswitch_ring:start(Node, Arec, AgentPid, Call, Timeout, Fun, [single_leg]),
			{reply, Out, State};
		false ->
			{reply, {error, noconnection}, State}
	end;
handle_call({get_media, MediaPid}, _From, #state{call_dict = Dict} = State) when is_pid(MediaPid) ->
	Folder = fun(Id, Pid, _Acc) ->
		case Pid of
			MediaPid ->
				Id;
			_ ->
				none
		end
	end,
	case dict:fold(Folder, none, Dict) of
		none ->
			{reply, none, State};
		Id ->
			{reply, {Id, MediaPid}, State}
	end;
handle_call({get_media, MediaKey}, _From, #state{call_dict = Dict} = State) ->
	case dict:find(MediaKey, Dict) of
		{ok, Pid} ->
			{reply, {MediaKey, Pid}, State};
		error ->
			{reply, none, State}
	end;
handle_call(Request, _From, State) ->
	?INFO("Unexpected call:  ~p", [Request]),
	Reply = ok,
	{reply, Reply, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% @private
handle_cast({channel_destroy, UUID}, #state{call_dict = Dict} = State) ->
	case dict:find(UUID, Dict) of
		{ok, Pid} ->
			Pid ! channel_destroy,
			{noreply, State};
		error ->
			{noreply, State}
	end;
handle_cast({notify, Callid, Pid}, #state{call_dict = Dict} = State) ->
	NewDict = dict:store(Callid, Pid, Dict),
	{noreply, State#state{call_dict = NewDict}};
handle_cast({new_voicemail, UUID, File, Queue, Priority, Client}, #state{nodename = Node} = State) ->
	{ok, Pid} = freeswitch_voicemail:start(Node, UUID, File, Queue, Priority, Client),
	link(Pid),
	{noreply, State};
handle_cast(_Msg, State) ->
	%?CONSOLE("Cast:  ~p", [Msg]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
%% @private
handle_info({freeswitch_sendmsg, "inivr "++UUID}, #state{call_dict = Dict} = State) ->
	?NOTICE("call ~s entered IVR", [UUID]),
	case dict:find(UUID, Dict) of
		{ok, Pid} ->
			Pid;
		error ->
			{ok, Pid} = freeswitch_media:start(State#state.nodename, State#state.dialstring, UUID),
			link(Pid)
	end,
	{noreply, State#state{call_dict = dict:store(UUID, Pid, Dict)}};
handle_info({get_pid, UUID, Ref, From}, #state{call_dict = Dict} = State) ->
	case dict:find(UUID, Dict) of
		{ok, Pid} ->
			?NOTICE("pid for ~s already allocated", [UUID]),
			Pid;
		error ->
			{ok, Pid} = freeswitch_media:start(State#state.nodename, State#state.dialstring, UUID),
			link(Pid)
	end,
	From ! {Ref, Pid},
	{noreply, State#state{call_dict = dict:store(UUID, Pid, Dict)}};
handle_info({'EXIT', Pid, Reason}, #state{eventserver = Pid, nodename = Nodename, freeswitch_up = true} = State) ->
	?NOTICE("listener pid exited unexpectedly: ~p", [Reason]),
	Lpid = start_listener(Nodename),
	freeswitch:event(Nodename, ['CHANNEL_DESTROY']),
	{noreply, State#state{eventserver = Lpid}};
handle_info({'EXIT', Pid, Reason}, #state{xmlserver = Pid, nodename = Nodename, dialstring = DialString, freeswitch_up = true} = State) ->
	?NOTICE("XML pid exited unexpectedly: ~p", [Reason]),
	{ok, NPid} = freeswitch:start_fetch_handler(Nodename, directory, ?MODULE, fetch_domain_user, [{dialstring, DialString}]),
	link(NPid),
	{noreply, State#state{xmlserver = NPid}};
handle_info({'EXIT', Pid, _Reason}, #state{eventserver = Pid} = State) ->
	{noreply, State#state{eventserver = undefined}};
handle_info({'EXIT', Pid, _Reason}, #state{xmlserver = Pid} = State) ->
	{noreply, State#state{xmlserver = undefined}};
handle_info({'EXIT', Pid, Reason}, #state{call_dict = Dict} = State) ->
	?NOTICE("trapped exit of ~p, doing clean up for ~p", [Reason, Pid]),
	F = fun(Key, Value, Acc) -> 
		case Value of
			Pid ->
				% TODO - do something with the CDR here - or try to restart the call!
				Acc;
			_Else ->
				dict:store(Key, Value, Acc)
		end
	end,
	NewDict = dict:fold(F, dict:new(), Dict),
	{noreply, State#state{call_dict = NewDict}};
handle_info({nodedown, Nodename}, #state{nodename = Nodename, xmlserver = Pid, eventserver = Lpid} = State) ->
	?WARNING("Freeswitch node ~p has gone down", [Nodename]),
	case is_pid(Pid) of
		true -> exit(Pid, kill);
		_ -> ok
	end,
	case is_pid(Lpid) of
		true -> exit(Lpid, kill);
		_ -> ok
	end,
	timer:send_after(1000, freeswitch_ping),
	{noreply, State#state{freeswitch_up = false}};
handle_info(freeswitch_ping, #state{nodename = Nodename} = State) ->
	case net_adm:ping(Nodename) of
		pong ->
			?NOTICE("Freeswitch node ~p is back up", [Nodename]),
			monitor_node(Nodename, true),
			Lpid = start_listener(Nodename),
			{ok, Pid} = freeswitch:start_fetch_handler(Nodename, directory, ?MODULE, fetch_domain_user, [{dialstring, State#state.dialstring}]),
			link(Pid),
			freeswitch:event(Nodename, ['CHANNEL_DESTROY']),
			{noreply, State#state{eventserver = Lpid, xmlserver = Pid, freeswitch_up = true}};
		pang ->
			timer:send_after(1000, freeswitch_ping),
			{noreply, State}
	end;
handle_info(Info, State) ->
	?DEBUG("Unexpected info:  ~p", [Info]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @private
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @private
start_listener(Nodename) ->
	Self = self(),
	spawn_link(fun() ->
				{freeswitchnode, Nodename} ! register_event_handler,
				receive
					ok ->
						Self ! {register_event_handler, {ok, self()}},
						listener(Nodename);
					{error, Reason} -> 
						Self ! {register_event_handler, {error, Reason}}
				after ?TIMEOUT -> 
						Self ! {register_event_handler, timeout}
				end
		end).

%% @private
% listens for info from the freeswitch c node.
listener(Node) ->
	receive
		{event, [UUID | Event]} ->
			?DEBUG("recieved event '~p' from c node.", [UUID]),
			Ename = freeswitch:get_event_name(Event),
			case Ename of
				"CHANNEL_DESTROY" ->
					gen_server:cast(?MODULE, {channel_destroy, UUID});
				_ ->
					ok
			end,
			listener(Node);
		{nodedown, Node} -> 
			gen_server:cast(?MODULE, nodedown);
		 Otherwise -> 
			 ?INFO("Uncertain reply received by the fmm listener:  ~p", [Otherwise]),
			 listener(Node)
	end.

-spec(fetch_domain_user/2 :: (Node :: atom(), State :: #state{}) -> 'ok').
fetch_domain_user(Node, State) ->
	?DEBUG("entering fetch loop with state ~p", [State]),
	receive
		{fetch, directory, "domain", "name", _Value, ID, [undefined | Data]} ->
			case proplists:get_value("as_channel", Data) of
				"true" ->
					User = proplists:get_value("user", Data),
					Domain = proplists:get_value("domain", Data),
					case agent_manager:query_agent(User) of
						{true, Pid} ->
							try agent:dump_state(Pid) of
								Agent ->
									DialString = case Agent#agent.endpointtype of
										sip_registration ->
											case Agent#agent.endpointdata of
												undefined ->
													"${sofia_contact("++User++"@"++Domain++")}";
												_ ->
													"${sofia_contact("++re:replace(Agent#agent.endpointdata, "@", "_", [{return, list}])++"@"++Domain++")}"
											end;
										sip ->
											"sofia/internal/sip:"++Agent#agent.endpointdata;
										iax2 ->
											"iax2/"++Agent#agent.endpointdata;
										h323 ->
											"opal/h323:"++Agent#agent.endpointdata;
										pstn ->
											freeswitch_media_manager:do_dial_string(proplists:get_value(dialstring, State, ""), Agent#agent.endpointdata, [])
									end,
									?NOTICE("returning ~s for user directory entry ~s", [DialString, User]),
									freeswitch:send(Node, {fetch_reply, ID, lists:flatten(io_lib:format(?DIALUSERRESPONSE, [Domain, User, DialString]))})
							catch
								_:_ -> % agent pid is toast?
									freeswitch:send(Node, {fetch_reply, ID, ?NOTFOUNDRESPONSE})
							end;
						false ->
							freeswitch:send(Node, {fetch_reply, ID, ?NOTFOUNDRESPONSE})
					end;
				_Else ->
					case proplists:get_value("action", Data) of
						"sip_auth" ->
							User = proplists:get_value("user", Data),
							Domain = proplists:get_value("domain", Data),
							Realm = proplists:get_value("sip_auth_realm", Data),
							case agent_manager:query_agent(User) of
								{true, Pid} ->
									try agent:dump_state(Pid) of
										Agent ->
											Password=Agent#agent.password,
											Hash = util:bin_to_hexstr(erlang:md5(User++":"++Realm++":"++Password)),
											agent_auth:set_extended_prop({login, Agent#agent.login}, a1_hash, Hash),
											freeswitch:send(Node, {fetch_reply, ID, lists:flatten(io_lib:format(?REGISTERRESPONSE, [Domain, User, Hash]))})
									catch
										_:_ -> % agent pid is toast?
											freeswitch:send(Node, {fetch_reply, ID, ?EMPTYRESPONSE})
									end;
								false ->
									case agent_auth:get_extended_prop({login, User}, a1_hash) of
										{ok, Hash} ->
											freeswitch:send(Node, {fetch_reply, ID, lists:flatten(io_lib:format(?REGISTERRESPONSE, [Domain, User, Hash]))});
										undefined ->
											freeswitch:send(Node, {fetch_reply, ID, ?EMPTYRESPONSE});
										{error, noagent} ->
											case agent_auth:get_extended_prop({login, re:replace(User, "_", "@", [{return, list}])}, a1_hash) of
												{ok, Hash} ->
													freeswitch:send(Node, {fetch_reply, ID, lists:flatten(io_lib:format(?REGISTERRESPONSE, [Domain, User, Hash]))});
												undefined ->
													freeswitch:send(Node, {fetch_reply, ID, ?EMPTYRESPONSE});
												{error, noagent} ->
													freeswitch:send(Node, {fetch_reply, ID, ?EMPTYRESPONSE})
											end
									end
							end;
						undefined -> % I guess we're just looking up a user?
							User = proplists:get_value("user", Data),
							Domain = proplists:get_value("domain", Data),
							case agent_manager:query_agent(User) of
								{true, _Pid} ->
									freeswitch:send(Node, {fetch_reply, ID, lists:flatten(io_lib:format(?USERRESPONSE, [Domain, User]))});
								false ->
									freeswitch:send(Node, {fetch_reply, ID, ?EMPTYRESPONSE})
							end;
						_ ->
							freeswitch:send(Node, {fetch_reply, ID, ?EMPTYRESPONSE})
					end
			end,
			?MODULE:fetch_domain_user(Node, State);
		{fetch, _Section, _Something, _Key, _Value, ID, [undefined | _Data]} ->
			freeswitch:send(Node, {fetch_reply, ID, ?EMPTYRESPONSE}),
			?MODULE:fetch_domain_user(Node, State);
		{nodedown, Node} ->
			?DEBUG("Node we were serving XML search requests to exited", []),
			ok;
		Other ->
			?DEBUG("got other response: ~p", [Other]),
			?MODULE:fetch_domain_user(Node, State)
	end.
