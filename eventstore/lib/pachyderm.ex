defmodule Pachyderm do
  def deliver(supervisor, entity_id, message) do
    {:ok, pid} = do_start(supervisor, entity_id)
    GenServer.call(pid, {:message, message})
  end

  def follow(supervisor, entity_id, cursor) do
    {:ok, pid} = do_start(supervisor, entity_id)
    GenServer.call(pid, {:follow, cursor})
  end

  def apply(a, b) do
  end

  defp do_start(supervisor, entity_id) do
    # network identifier ->
    # apply(1, 2)

    starting =
      DynamicSupervisor.start_child(supervisor, %{
        # Why does DynamicSupervisor require an id, you cannot delete by it.
        id: nil,
        start: {__MODULE__, :start_supervised, [entity_id]}
      })

    case starting do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}
    end
  end

  def start_supervised(config, entity_id) do
    start_link(entity_id, config)
  end

  def start_link(entity_id, config) do
    GenServer.start_link(__MODULE__, %{config: config, entity_id: entity_id},
      name: {:global, entity_id}
    )
  end

  def init(init) do
    %{config: config, entity_id: entity_id} = init

    {:ok, storage_events} =
      case EventStore.read_stream_forward(entity_id, 0) do
        {:ok, storage_events} ->
          {:ok, storage_events}

        {:error, :stream_not_found} ->
          {:ok, []}
      end

    events = Enum.map(storage_events, & &1.data)
    entity_state = Enum.reduce(events, %{count: 0}, &Example.Counter.apply/2)

    {:ok,
     %{
       entity_state: entity_state,
       events: events,
       followers: %{},
       config: config,
       entity_id: entity_id
     }}
  end

  def handle_call({:message, message}, _from, state) do
    %{
      entity_state: entity_state,
      events: saved_events,
      followers: followers,
      config: config,
      entity_id: entity_id
    } = state

    case Example.Counter.execute(message, entity_state) do
      {:ok, reaction} ->
        {actions, new_events} =
          case reaction do
            {actions, new_events} ->
              {actions, new_events}

            new_events when is_list(new_events) ->
              {[], new_events}
          end

        events = saved_events ++ new_events
        # Correlation vs causation
        # Also what is metadata
        # TODO test validity of actions before saving events
        storage_events =
          for event <- new_events do
            %EventStore.EventData{event_type: nil, data: event}
          end

        :ok = EventStore.append_to_stream(entity_id, length(saved_events), storage_events)

        entity_state = Enum.reduce(new_events, entity_state, &Example.Counter.apply/2)

        for {_monitor, follower} <- followers do
          send(follower, {:events, new_events})
        end

        # Could be a struct, but behaviour more sensible than protocol
        for {action_module, action_payload} <- actions do
          action_module.dispatch(action_payload, config)
        end

        state = %{state | entity_state: entity_state, events: events}
        {:reply, {:ok, entity_state}, state}
    end
  end

  def handle_call({:follow, cursor}, from, state) do
    %{events: events, followers: followers} = state
    # Any harm in reusing ref for subscription_id, probably actually use the ref from monitoring
    {follower, _ref} = from

    # follow more that once? probably not, but can use monitor as subscription_id
    monitor = Process.monitor(follower)
    followers = Map.put(followers, monitor, follower)

    count = length(events)

    state = %{state | followers: followers}
    {:reply, {:ok, count}, state, {:continue, {:send_follower, follower, events}}}
  end

  def handle_continue({:send_follower, follower, events}, state) do
    send(follower, {:events, events})
    {:noreply, state}
  end
end