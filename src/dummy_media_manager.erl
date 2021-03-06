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
%%	Micah Warren <micahw at lordnull dot com>
%%

%% @doc A media manager for dummy_media.
%% @see dummy_media

-module(dummy_media_manager).
-author(micahw).

-behaviour(gen_server).

-include_lib("oacd_core/include/log.hrl").
-include_lib("oacd_core/include/cpx.hrl").
-include_lib("oacd_core/include/call.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
	start_link/1,
	start/1,
	start_supervised/1,
	stop/0,
	stop_supped/0,
	halt/0,
	set_option/2,
	get_media/1,
	spawn_call/0,
	spawn_call/1,
	agent_web_path/4,
	agent_web_call/5
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(conf, {
	call_frequency = {distribution, 110} :: any(),
	call_max_life = {distribution, 900} :: any(),
	queues = any :: any(),
	call_priority = {distribution, 20} :: any()
}).
-record(state, {
	conf = #conf{} :: #conf{},
	calls = [] :: [{pid(), string()}],
	timer :: any()
}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include_lib("oacd_core/include/gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
-spec(start_link/1 :: (Options :: [{atom(), any()}]) -> {'ok', pid()}).
start_link(Options) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

-spec(start/1 :: (Options :: [{atom(), any()}]) -> {'ok', pid()}).
start(Options) ->
	gen_server:start({local, ?MODULE}, ?MODULE, Options, []).

-spec(start_supervised/1 :: (Options :: [{atom(), any()}]) -> {'ok', pid()}).
start_supervised(Options) ->
	Conf = #cpx_conf{
		id = ?MODULE,
		module_name = ?MODULE,
		start_function = start_link,
		start_args = [Options]
	},
	cpx_middle_supervisor:add_with_middleman(mediamanager_sup, 3, 5, Conf).

-spec(stop/0 :: () -> 'ok').
stop() ->
	gen_server:cast(?MODULE, {stop, normal}).

-spec(stop_supped/0 :: () -> 'ok').
stop_supped() ->
	cpx_middle_supervisor:drop_child(mediamanager_sup, dummy_media_manager).

-spec(set_option/2 :: (Key :: atom(), Valu :: any()) -> 'ok').
set_option(Key, Valu) ->
	gen_server:cast(?MODULE, {set_option, Key, Valu}).
	
-spec(get_media/1 :: (MediaKey :: pid() | string()) -> {string(), pid()} | 'none').
get_media(MediaKey) ->
	gen_server:call(?MODULE, {get_media, MediaKey}).

-spec(halt/0 :: () -> 'ok').
halt() ->
	gen_server:cast(?MODULE, halt).

-spec(spawn_call/0 :: () -> 'ok').
spawn_call() ->
	dummy_media_manager ! spawn_call,
	ok.
-spec(spawn_call/1 :: (Options :: [{atom(), any()}]) -> 'ok').
spawn_call(Options) ->
	dummy_media_manager ! {spawn_call, Options},
	ok.

agent_web_path([$/,$d,$u,$m,$m,$y,$/ | Path], _Post, _, PrivDir) ->
	File = filename:join([PrivDir, "www", Path]),
	case filelib:is_file(File) of
		false ->
			?DEBUG("Couldn't find file ~s (cwd:  ~p)", [File, file:get_cwd()]),
			{error, not_found};
		true -> file:read_file(File)
	end;

agent_web_path(Path, _, _, _) ->
	?DEBUG("Got gonna do anything for ~p", [Path]),
	{error, not_found}.

agent_web_call(_Agentrec, _Conn, <<"get_happy">>, [], Priv) ->
	File = filename:join([Priv, "www", "dummy_media.html"]),
	{ok, Bin} = file:read_file(File),
	{ok, {ok, Bin}}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%--------------------------------------------------------------------
init(Options) ->
	cpx_hooks:set_hook(dummy_html_get, agent_web_path, {dummy_media_manager, agent_web_path, [code:priv_dir(oacd_dummy)]}),
	cpx_hooks:set_hook(dummy_web_res, agent_web_call, {dummy_media_manager, agent_web_call, [code:priv_dir(oacd_dummy)]}),
	process_flag(trap_exit, true),
	Conf = #conf{
		call_frequency = proplists:get_value(call_frequency, Options, {distribution, 110}),
		call_max_life = proplists:get_value(call_max_life, Options, {distribution, 900}),
		queues = proplists:get_value(queues, Options, any),
		call_priority = proplists:get_value(call_priority, Options, {distribution, 20})
	},
	Seeds = proplists:get_value(start_count, Options, 10),
	Self = self(),
	Fun = fun(_) ->
		Pid = queue_media(Conf),
		unlink(Pid),
		try gen_media:get_call(Pid) of
			Call ->
				gen_server:cast(Self, {add_call, {Pid, Call#call.id}})
		catch
			_:_ ->
				?NOTICE("new dummy call dropped instantly", [])
		end
	end,
	spawn(fun() ->
				[Fun(X) || X <- lists:seq(1, Seeds)]
		end),
	Timer = spawn_timer(Conf#conf.call_frequency),
	{ok, #state{
			calls = [],
			conf = Conf,
			timer = Timer
		}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%--------------------------------------------------------------------
handle_call(get_count, _, #state{calls = Pidlist} = State) ->
	{reply, {ok, length(Pidlist)}, State};
handle_call({get_media, MediaPid}, _From, #state{calls = Pidlist} = State) when is_pid(MediaPid) ->
	case proplists:get_value(MediaPid, Pidlist) of
		undefined ->
			{reply, none, State};
		Id ->
			{reply, {Id, MediaPid}, State}
	end;
handle_call({get_media, Needle}, _From, #state{calls = Pidlist} = State) ->
	case lists:keyfind(Needle, 2, Pidlist) of
		false ->
			{reply, none, State};
		{Pid, Needle} ->
			{reply, {Needle, Pid}, State}
	end;
handle_call({get_call, Needle}, From, State) ->
	handle_call({get_media, Needle}, From, State);
handle_call(Request, _From, State) ->
    {reply, {invalid, Request}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_cast({set_option, Option, Arg}, #state{conf = Conf} = State) ->
	Newconf = case Option of
		call_frequency ->
			Conf#conf{call_frequency = Arg};
		call_max_life ->
			Conf#conf{call_max_life = Arg};
		queues ->
			Conf#conf{queues = Arg};
		call_priority ->
			Conf#conf{call_priority = Arg};
		_Else ->
			?WARNING("unknown option ~p", [Option]),
			Conf
	end,
	{noreply, State#state{conf = Newconf}};
handle_cast({stop, Why}, State) when Why =:= normal orelse Why =:= shutdown ->
	{stop, Why, State};
handle_cast({add_call, {Pid, Call}}, State) ->
	link(Pid),
	{noreply, State#state{calls = [{Pid, Call} | State#state.calls]}};
handle_cast(halt, State) ->
	erlang:cancel_timer(State#state.timer),
	{noreply, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_info(spawn_call, #state{calls = Pidlist, conf = Conf} = State) ->
	Newpid = queue_media(State#state.conf),
	Timer = spawn_timer(Conf#conf.call_frequency),
	try gen_media:get_call(Newpid) of
		#call{id = Newid} ->
			{noreply, State#state{calls = [{Newpid, Newid} | Pidlist], timer = Timer}}
	catch
		exit:Reason ->
			?WARNING("Newly spawned call not found: ~p", [Reason]),
			{noreply, State#state{timer = Timer}}
	end;
handle_info({spawn_call, Opts}, #state{calls = Pidlist} = State) ->
	Fakeconf = #conf{
		queues = proplists:get_value(queues, Opts, any),
		call_max_life = proplists:get_value(max_life, Opts),
		call_priority = proplists:get_value(priority, Opts)
	},
	Newpid = queue_media(Fakeconf),
	try gen_media:get_call(Newpid) of
		#call{id = Newid} ->
			{noreply, State#state{calls = [{Newpid, Newid} | Pidlist]}}
	catch
		exit:Reason ->
			?WARNING("Newly spawned call not found: ~p", [Reason]),
			{noreply, State}
	end;
handle_info({'EXIT', _Reason, Pid}, #state{calls = Pidlist} = State) ->
	case proplists:get_value(Pid, Pidlist) of
		undefined ->
			{noreply, State};
		Id ->
			cpx_monitor:drop({media, Id}),
			Newlist = proplists:delete(Pid, Pidlist),
			{noreply, State#state{calls = Newlist}}
	end;
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(_Reason, #state{calls = Pidlist}) ->
	Fun = fun({_Pid, Id}) ->
		cpx_monitor:drop({media, Id})
	end,
	lists:foreach(Fun, Pidlist),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

queue_media(Conf) ->
	{ok, Pid} = dummy_media:q([
		{queues, Conf#conf.queues}, 
		{max_life, util:get_number(Conf#conf.call_max_life)},
		{priority, Conf#conf.call_priority}
	]),
	Pid.

spawn_timer(never) ->
	undefined;
spawn_timer(Num) ->
	Time = util:get_number(Num) * 1000,
	?INFO("Spawning new call after ~p", [Time]),
	erlang:send_after(Time, ?MODULE, spawn_call).
