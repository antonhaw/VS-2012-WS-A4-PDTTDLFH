-module(sender).

-behaviour(gen_fsm).

%% API
-export([start/4]).

%% gen_fsm callbacks
-export([init/1,
         waiting_for_slot/2,
         waiting_for_input/2,
         revising_next_slot/2,
         send_message/2,
         state_name/3,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-record(state, {datasource_pid :: pid(), % PID of the datasource gen_server
                sending_socket,          %
                multicast_ip,            % IP used for broadcast
                receiving_port,          %
                coordinator_pid :: pid(),% PID of the coordinator gen_server
                slot,                    % slot of each frame used for sending
                data,                     % data to broadcast
				timestamp_aspired_sending,
				timestamp_revising,
				timestamp_sending,
				timestamp_sent,
				sending_time_difference = []
               }).

start(CoordinatorPID, SendingSocket, MulticastIP, ReceivingPort) ->
  gen_fsm:start(?MODULE, [CoordinatorPID,
                          SendingSocket,
                          MulticastIP,
                          ReceivingPort], []).

init([CoordinatorPID, SendingSocket, MulticastIP, ReceivingPort]) ->
  {ok, DataSourcePID} = datasource:start(),
  {ok, waiting_for_slot, #state{datasource_pid  = DataSourcePID,
                                sending_socket  = SendingSocket,
                                multicast_ip    = MulticastIP,
                                receiving_port  = ReceivingPort,
                                coordinator_pid = CoordinatorPID
                               }}.

waiting_for_slot({slot, Slot}, State) ->
  utility:log(io:format("waiting_for_slot: {slot, ~p}~n", [Slot])),
  gen_server:cast(State#state.datasource_pid,{get_data, self()}),
  {next_state, waiting_for_input, State#state{slot = Slot}};
waiting_for_slot(Event, State) ->
  utility:log(io:format("waiting_for_slot: unknown event: ~p~n", [Event])),
  {next_state, waiting_for_slot, State}.

waiting_for_input({input, Data}, State) ->
  utility:log(io:format("waiting_for_input: {input, ~p}~n", [Data])),
  case Data == [] of
	true ->
		utility:log(io:format("waiting_for_input: data empty, waiting for next frame~n")),
		{next_state, waiting_for_slot, State};
	false ->
	  AvgTimeDiff = min(average(State#state.sending_time_difference),0), %0 = no adjustment at all time
	  AspiredSendingTime = utility:current_timestamp()+utility:time_until_slot(State#state.slot, AvgTimeDiff),
	  utility:log(io:format("should send: ~p~n", [AspiredSendingTime])),
	  gen_fsm:send_event_after(utility:time_until_slot(State#state.slot, AvgTimeDiff), revise_next_slot),
	  {next_state, revising_next_slot, State#state{data = Data, timestamp_aspired_sending=AspiredSendingTime}}
  end;

waiting_for_input(Event, State) ->
  utility:log(io:format("waiting_for_input: unknown event: ~p~n", [Event])),
  {next_state, waiting_for_input, State}.

revising_next_slot(revise_next_slot, State) ->
  utility:log(io:format("revising_next_slot: ~p~n", [State#state.slot])),
  RevisingTime = utility:current_timestamp(),
  utility:log(io:format("should send now: ~p~n", [RevisingTime])),
  gen_server:cast(State#state.coordinator_pid,{revise_next_slot, State#state.slot}),
  {next_state, send_message, State#state{timestamp_revising=RevisingTime}};
revising_next_slot(Event, State) ->
  utility:log(io:format("revising_next_slot: unknown event: ~p~n", [Event])),
  {next_state, revising_next_slot, State}.

send_message({next_slot, NextSlot}, State) ->
  utility:log(io:format("send_message: next_slot ~p~n", [NextSlot])),
  Packet = build_packet(State#state.data, NextSlot),
  SendingTime = utility:current_timestamp(),
  utility:log(io:format("sending now ~p~n", [utility:current_timestamp()])),
  gen_udp:send(State#state.sending_socket,
               State#state.multicast_ip,
               State#state.receiving_port,
               Packet),
  SentTime = utility:current_timestamp(),
  SendingTimeDifference = SentTime - State#state.timestamp_aspired_sending,
  SendingTimeDifferenceList = [SendingTimeDifference | State#state.sending_time_difference],
  AvarageDifference = average(SendingTimeDifferenceList),
  utility:log(io:format("sent ~p [Diff.: ~p Avg.: ~p]~n", [SentTime,SendingTimeDifference,AvarageDifference])),		 

  {next_state, waiting_for_slot, State#state{timestamp_sending=SendingTime, timestamp_sent=SentTime, sending_time_difference=SendingTimeDifferenceList}};
send_message(Event, State) ->
  utility:log(io:format("send_message: unknown event: ~p~n", [Event])),
  {next_state, send_message, State}.
  
average(List) ->
  case length(List) > 0 of
  true ->
    lists:sum(List) / length(List);
  false ->
    0
  end.

handle_event(kill, _StateName, State) ->
  {stop, normal, State}.

%%% do everything required for a clean shutdown
terminate(_Reason, _StateName, State) ->
  gen_server:cast(State#state.datasource_pid, kill),
  gen_udp:close(State#state.sending_socket),
  ok.




%%% Helper functions
build_packet(Data, Slotwish) ->
  EncodedData = list_to_binary(Data),
  Timestamp   = utility:current_timestamp(),

  <<EncodedData:24/binary,
    Slotwish:8/integer-big,
    Timestamp:64/integer-big
  >>.


%%% OTP gen_fsm boilerplate - ignore this
state_name(_Event, _From, State) ->
  Reply = ok,
  {reply, Reply, state_name, State}.

handle_sync_event(_Event, _From, StateName, State) ->
  Reply = ok,
  {reply, Reply, StateName, State}.

handle_info(_Info, StateName, State) ->
  {next_state, StateName, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
  {ok, StateName, State}.
