defmodule DashboardWeb.StatusComponents do
  @moduledoc """
  Function components for the dashboard page: a header, a row of summary
  tiles, and one card per mechanism (runners, job slots, queue, device lock,
  host, events).

  Every status is stated in words and marked with a shaped icon; colour only
  reinforces it. Components take structs and `now`, call `Dashboard.Overview`
  for anything derived, and hold no logic of their own beyond wording.
  """

  use Phoenix.Component

  alias Dashboard.{Overview, Snapshot, Source}
  alias Dashboard.Status
  alias Dashboard.Status.{DeviceLock, Host, Slots}

  @events_shown 20

  ## Header and notices

  attr :snapshot, Snapshot, required: true
  attr :now, :integer, required: true

  def page_header(assigns) do
    ~H"""
    <header class="page-header">
      <div>
        <h1>Runner host</h1>
        <p class="muted">github-runner-manager</p>
      </div>
      <div class="page-header-status">
        <span :if={@snapshot.demo} class="badge badge-accent" id="demo-badge">
          <.icon name={:info} /> Demo data
        </span>
        <.freshness snapshot={@snapshot} now={@now} />
        <button type="button" class="theme-toggle" id="theme-toggle" phx-update="ignore">
          Theme: auto
        </button>
      </div>
    </header>
    """
  end

  attr :snapshot, Snapshot, required: true
  attr :now, :integer, required: true

  defp freshness(%{snapshot: %Snapshot{error: nil, status: nil}} = assigns) do
    ~H"""
    <span class="badge badge-neutral" id="freshness"><.icon name={:waiting} /> Reading…</span>
    """
  end

  defp freshness(%{snapshot: %Snapshot{error: nil}} = assigns) do
    ~H"""
    <span
      class="badge badge-ok"
      id="freshness"
      title="Time since runners, slots, queue, lock or events last changed. Load and memory are sampled on every reading."
    >
      <.icon name={:ok} /> Live
      <span class="badge-detail">
        changed {Overview.format_duration(Overview.elapsed(@snapshot.changed_at, @now))} ago
      </span>
    </span>
    """
  end

  defp freshness(assigns) do
    ~H"""
    <span class="badge badge-bad" id="freshness">
      <.icon name={:problem} /> Stale
      <span class="badge-detail">
        {Overview.format_duration(Overview.elapsed(@snapshot.stale_since, @now))}
      </span>
    </span>
    """
  end

  attr :snapshot, Snapshot, required: true
  attr :now, :integer, required: true

  def stale_notice(assigns) do
    ~H"""
    <div class="notice notice-bad" role="status" id="stale-notice">
      <.icon name={:problem} />
      <p>
        <strong>
          Stale data: the last good reading is {Overview.format_duration(
            Overview.elapsed(@snapshot.stale_since, @now)
          )} old.
        </strong>
        Reading failed: {Source.describe_error(@snapshot.error)}. Still retrying, less often.
      </p>
    </div>
    """
  end

  attr :snapshot, Snapshot, required: true

  def no_reading(%{snapshot: %Snapshot{error: nil}} = assigns) do
    ~H"""
    <main class="empty-page" id="no-reading">
      <.icon name={:waiting} />
      <h2>Reading the host…</h2>
      <p class="muted">The first reading has not arrived yet.</p>
    </main>
    """
  end

  def no_reading(assigns) do
    ~H"""
    <main class="empty-page" id="no-reading">
      <.icon name={:problem} />
      <h2>No reading yet</h2>
      <p>Reading failed: {Source.describe_error(@snapshot.error)}.</p>
      <p class="muted">
        Check that <code>bin/grm-status --json</code>
        works for the user running the dashboard. Retrying in the background.
      </p>
    </main>
    """
  end

  ## Summary tiles

  attr :status, Status, required: true
  attr :now, :integer, required: true

  def summary(assigns) do
    assigns =
      assigns
      |> assign(:counts, Overview.runner_counts(assigns.status))
      |> assign(:pool, Overview.utilisation(assigns.status.slots))
      |> assign(:waiting, length(Overview.queue(assigns.status.slots)))
      |> assign(:longest, Overview.longest_wait(assigns.status.slots, assigns.now))
      |> assign(:lock, Overview.lock_condition(assigns.status.device_lock))
      |> assign(:gate, Overview.load_gate(assigns.status.host))

    ~H"""
    <section class="summary" aria-label="Summary">
      <.tile label="Runners" id="tile-runners" tone={if @counts.down > 0, do: :bad, else: :plain}>
        <:value>
          {busy(@counts)}<span class="tile-of"> / {length(@status.runners)} busy</span>
        </:value>
        <:detail>
          {@counts.idle} idle<span :if={@counts.down > 0}> · {@counts.down} down</span>
        </:detail>
      </.tile>

      <.tile label="Job slots" id="tile-slots" tone={if @pool.overcommitted, do: :warn, else: :plain}>
        <:value>
          {@pool.used}<span class="tile-of"> / {@pool.capacity} units</span>
        </:value>
        <:detail>{pool_words(@pool)}</:detail>
      </.tile>

      <.tile label="Queue" id="tile-queue" tone={if @waiting > 0, do: :warn, else: :plain}>
        <:value>
          {@waiting}<span class="tile-of"> waiting</span>
        </:value>
        <:detail>
          <span :if={@waiting == 0}>nobody is held back</span>
          <span :if={@waiting > 0}>longest {Overview.format_duration(@longest)}</span>
        </:detail>
      </.tile>

      <.tile label="Device lock" id="tile-lock" tone={lock_tone(@lock)}>
        <:value>{lock_word(@lock)}</:value>
        <:detail>{lock_summary(@status.device_lock, @lock, @now)}</:detail>
      </.tile>

      <.tile label="Load gate" id="tile-gate" tone={if @gate.open, do: :plain, else: :warn}>
        <:value>{if @gate.open, do: "Open", else: "Closed"}</:value>
        <:detail>
          load {number(@status.host.load_1m)} / {number(@status.host.max_load)} · {Overview.format_memory(
            @status.host.memory_available_mb
          )} GB free
        </:detail>
      </.tile>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :id, :string, required: true
  attr :tone, :atom, values: [:plain, :warn, :bad], default: :plain
  slot :value, required: true
  slot :detail, required: true

  defp tile(assigns) do
    ~H"""
    <div class={["tile", "tile-#{@tone}"]} id={@id}>
      <p class="tile-label">
        {@label}
        <.icon :if={@tone == :warn} name={:attention} />
        <.icon :if={@tone == :bad} name={:problem} />
      </p>
      <p class="tile-value">{render_slot(@value)}</p>
      <p class="tile-detail">{render_slot(@detail)}</p>
    </div>
    """
  end

  defp busy(counts), do: counts.running + counts.queued + counts.parked

  defp pool_words(%{overcommitted: true} = pool),
    do: "overcommitted by #{pool.used - pool.capacity}"

  defp pool_words(%{free: 0}), do: "full"
  defp pool_words(%{free: free}), do: "#{free} free"

  defp lock_word(:absent), do: "Unused"
  defp lock_word(:free), do: "Free"
  defp lock_word(:held), do: "Held"
  defp lock_word(:orphaned), do: "Unclaimed"
  defp lock_word(:stale), do: "Stale"

  defp lock_tone(:stale), do: :bad
  defp lock_tone(:orphaned), do: :warn
  defp lock_tone(_condition), do: :plain

  defp lock_summary(%DeviceLock{holder: holder}, :held, now),
    do: "#{holder.repository} · #{Overview.format_duration(Overview.elapsed(holder.since, now))}"

  defp lock_summary(%DeviceLock{stale: stale}, :stale, _now),
    do: "#{length(stale)} stale #{plural(length(stale), "holder")}"

  defp lock_summary(_lock, :orphaned, _now), do: "held, no live wrapper"
  defp lock_summary(_lock, :free, _now), do: "nobody has the device"
  defp lock_summary(_lock, :absent, _now), do: "never taken on this host"

  ## Runners

  attr :status, Status, required: true
  attr :now, :integer, required: true

  def runners_card(assigns) do
    assigns =
      assigns
      |> assign(:rows, Overview.runners(assigns.status))
      |> assign(:device_repository, device_repository(assigns.status.device_lock))

    ~H"""
    <section class="card" id="runners" aria-labelledby="runners-title">
      <header class="card-header">
        <h2 id="runners-title">Runners</h2>
        <p class="muted">{length(@rows)} configured</p>
      </header>
      <p :if={@rows == []} class="empty">
        No runners configured. List them in <code>GRM_RUNNERS</code>
        and install their units with <code>grm-install-runner</code>.
      </p>
      <ul :if={@rows != []} class="rows">
        <li :for={row <- @rows} class="row" id={"runner-#{row.runner.name}"}>
          <div class="row-main">
            <p class="row-title">{row.runner.name}</p>
            <p class="muted">{row.runner.repository}</p>
          </div>
          <div class="row-side">
            <p class={["state", "state-#{row.activity}"]}>
              <.icon name={activity_icon(row.activity)} /> {activity_word(row.activity)}
            </p>
            <p class="muted">
              {activity_detail(row, @now)}
              <span
                :if={row.activity == :running and row.runner.repository == @device_repository}
                class="chip"
              >
                has the device
              </span>
            </p>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp device_repository(%DeviceLock{
         state: :held,
         holder: %{alive: true, repository: repository}
       }),
       do: repository

  defp device_repository(_lock), do: nil

  defp activity_word(:running), do: "Running"
  defp activity_word(:queued), do: "Waiting for slots"
  defp activity_word(:parked), do: "Waiting for device"
  defp activity_word(:idle), do: "Idle"
  defp activity_word(:down), do: "Down"

  defp activity_icon(:running), do: :active
  defp activity_icon(:queued), do: :waiting
  defp activity_icon(:parked), do: :waiting
  defp activity_icon(:idle), do: :idle
  defp activity_icon(:down), do: :problem

  defp activity_detail(%{activity: :down, runner: runner}, _now), do: "unit #{runner.unit_state}"
  defp activity_detail(%{activity: :idle}, _now), do: "ready for a job"
  defp activity_detail(%{record: nil}, _now), do: "outside the slot gate"

  defp activity_detail(%{activity: :running, record: record}, now),
    do: "#{units(record.units)} · #{since(record, now)}"

  defp activity_detail(%{activity: :queued, record: record}, now),
    do: "needs #{units(record.units)} · #{since(record, now)}"

  defp activity_detail(%{activity: :parked, record: record}, now),
    do: "returned #{units(record.units)} · #{since(record, now)}"

  ## Job slots

  attr :slots, Slots, required: true
  attr :now, :integer, required: true

  def slots_card(assigns) do
    assigns =
      assigns
      |> assign(:pool, Overview.utilisation(assigns.slots))
      |> assign(:holders, Overview.holders(assigns.slots))
      |> assign(:parked, Overview.parked(assigns.slots))

    ~H"""
    <section class="card" id="slots" aria-labelledby="slots-title">
      <header class="card-header">
        <h2 id="slots-title">Job slots</h2>
        <p class="muted">{@pool.used} of {units(@pool.capacity)} in use</p>
      </header>

      <div
        class="pool"
        role="img"
        aria-label={"#{@pool.used} of #{@pool.capacity} units in use, #{pool_words(@pool)}"}
      >
        <span :for={cell <- pool_cells(@holders, @pool)} class={["cell", "cell-#{cell}"]}></span>
      </div>

      <p :if={@pool.overcommitted} class="notice notice-warn">
        <.icon name={:attention} />
        <span>
          Overcommitted: a job larger than the pool entered alone, or a job was admitted after the
          maximum wait.
        </span>
      </p>

      <p :if={@holders == []} class="empty">No job holds units.</p>
      <ul :if={@holders != []} class="rows rows-tight">
        <li :for={{record, index} <- Enum.with_index(@holders)} class="row">
          <div class="row-main">
            <p class="row-title">
              <span class={["swatch", "cell-#{holder_style(index)}"]}></span>
              {record.label}
            </p>
          </div>
          <div class="row-side">
            <p>{units(record.units)}</p>
            <p class="muted">for {since(record, @now)}</p>
          </div>
        </li>
      </ul>

      <div :if={@parked != []} id="parked">
        <h3>Parked</h3>
        <ul class="rows rows-tight">
          <li :for={record <- @parked} class="row">
            <div class="row-main">
              <p class="row-title">{record.label}</p>
              <p class="muted">gave back {units(record.units)} while it waits for the device</p>
            </div>
            <div class="row-side">
              <p class="muted">{since(record, @now)}</p>
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  # One cell per unit: holders' units first (alternating two styles so adjacent
  # holders stay distinguishable without colour), then free units. Units past
  # capacity are drawn as overcommitted.
  defp pool_cells(holders, pool) do
    held =
      holders
      |> Enum.with_index()
      |> Enum.flat_map(fn {record, index} ->
        List.duplicate(holder_style(index), record.units)
      end)

    {within, beyond} = Enum.split(held, pool.capacity)

    within ++
      List.duplicate("free", pool.capacity - length(within)) ++
      Enum.map(beyond, fn _ -> "over" end)
  end

  defp holder_style(index), do: if(rem(index, 2) == 0, do: "held-a", else: "held-b")

  ## Queue

  attr :slots, Slots, required: true
  attr :now, :integer, required: true

  def queue_card(assigns) do
    assigns = assign(assigns, :queue, Overview.queue(assigns.slots))

    ~H"""
    <section class="card" id="queue" aria-labelledby="queue-title">
      <header class="card-header">
        <h2 id="queue-title">Queue</h2>
        <p class="muted">admitted in this order</p>
      </header>
      <p :if={@queue == []} class="empty">Nobody is waiting for units.</p>
      <ol :if={@queue != []} class="rows rows-tight queue">
        <li :for={{record, index} <- Enum.with_index(@queue, 1)} class="row">
          <span class="position" aria-hidden="true">{index}</span>
          <div class="row-main">
            <p class="row-title">{record.label}</p>
            <p class="muted">
              needs {units(record.units)} · ticket {record.ticket}
              <span :if={record.kind == :parked} class="chip">back from the device</span>
            </p>
          </div>
          <div class="row-side">
            <p>{since(record, @now)}</p>
            <p :if={Overview.overdue?(record, @slots, @now)} class="state state-queued">
              <.icon name={:attention} /> past the maximum wait
            </p>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  ## Device lock

  attr :lock, DeviceLock, required: true
  attr :now, :integer, required: true

  def device_lock_card(assigns) do
    assigns = assign(assigns, :condition, Overview.lock_condition(assigns.lock))

    ~H"""
    <section class="card" id="device-lock" aria-labelledby="device-lock-title">
      <header class="card-header">
        <h2 id="device-lock-title">Device lock</h2>
        <p class={["state", "state-lock-#{@condition}"]}>
          <.icon name={lock_icon(@condition)} /> {lock_word(@condition)}
        </p>
      </header>

      <p :if={@condition == :absent} class="empty">
        The device lock has never been taken on this host.
      </p>
      <p :if={@condition == :free} class="empty">Nobody has the device.</p>

      <dl :if={@lock.state == :held and @lock.holder} class="facts">
        <div>
          <dt>Repository</dt>
          <dd>{@lock.holder.repository}</dd>
        </div>
        <div>
          <dt>Job</dt>
          <dd>{@lock.holder.job}</dd>
        </div>
        <div>
          <dt>Run</dt>
          <dd class="mono">{@lock.holder.run_id}</dd>
        </div>
        <div>
          <dt>Held for</dt>
          <dd>{Overview.format_duration(Overview.elapsed(@lock.holder.since, @now))}</dd>
        </div>
        <div>
          <dt>Wrapper</dt>
          <dd>
            <span class="mono">pid {@lock.holder.pid}</span>
            <span :if={!@lock.holder.alive}> · no longer running</span>
          </dd>
        </div>
      </dl>

      <p :if={@condition == :orphaned} class="notice notice-warn" id="lock-orphaned">
        <.icon name={:attention} />
        <span>
          The lock is held but no live wrapper claims it: a process probably inherited it. The
          watchdog reports such a holder once it is {Overview.format_duration(
            @lock.watchdog_min_age_seconds
          )} old.
        </span>
      </p>

      <div :if={@condition == :stale} class="notice notice-bad" id="lock-stale">
        <.icon name={:problem} />
        <div>
          <p><strong>Stale: the lock is held by a process that is not the wrapper.</strong></p>
          <ul class="plain">
            <li :for={holder <- @lock.stale}>
              <span class="mono">{holder.command}</span>
              · <span class="mono">pid {holder.pid}</span>
              · fd {holder.fd} · process age {Overview.format_duration(holder.age_seconds)}
            </li>
          </ul>
          <p :if={!@lock.watchdog_kill}>
            The watchdog is report-only; nothing will be stopped automatically.
          </p>
          <p :if={@lock.watchdog_kill}>
            Kill mode is on: the watchdog sends TERM to allow-listed commands on its next run.
          </p>
        </div>
      </div>

      <p :if={@condition in [:free, :held]} class="muted watchdog">
        Watchdog: no stale holders. It reports holders older than {Overview.format_duration(
          @lock.watchdog_min_age_seconds
        )}{if @lock.watchdog_kill, do: " and stops allow-listed ones", else: ", report-only"}.
      </p>
    </section>
    """
  end

  defp lock_icon(:absent), do: :idle
  defp lock_icon(:free), do: :idle
  defp lock_icon(:held), do: :active
  defp lock_icon(:orphaned), do: :attention
  defp lock_icon(:stale), do: :problem

  ## Host

  attr :host, Host, required: true

  def host_card(assigns) do
    assigns = assign(assigns, :gate, Overview.load_gate(assigns.host))

    ~H"""
    <section class="card" id="host" aria-labelledby="host-title">
      <header class="card-header">
        <h2 id="host-title">Host</h2>
        <p class={["state", if(@gate.open, do: "state-idle", else: "state-queued")]}>
          <.icon name={if @gate.open, do: :ok, else: :attention} />
          {if @gate.open, do: "Load gate open", else: "Load gate closed"}
        </p>
      </header>

      <div class="meters">
        <.meter
          id="meter-load"
          label="Load, 1 min"
          value={number(@host.load_1m)}
          limit={"limit #{number(@host.max_load)}"}
          percent={Overview.meter_percent(@host.load_1m, @host.max_load && @host.max_load * 2)}
          verdict={load_verdict(@gate.load)}
          problem={@gate.load != :ok}
        />
        <.meter
          id="meter-memory"
          label="Memory available"
          value={"#{Overview.format_memory(@host.memory_available_mb)} GB"}
          limit={"minimum #{Overview.format_memory(@host.min_memory_mb)} GB"}
          percent={
            Overview.meter_percent(
              @host.memory_available_mb,
              @host.min_memory_mb && @host.min_memory_mb * 2
            )
          }
          verdict={memory_verdict(@gate.memory)}
          problem={@gate.memory != :ok}
        />
      </div>
      <p class="muted">
        <code>wait-for-load</code>
        lets a heavy step start when load is below the limit and memory is at or above the minimum{if @host.cpus,
          do: "; #{@host.cpus} CPUs",
          else: ""}.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :limit, :string, required: true
  attr :percent, :integer, required: true
  attr :verdict, :string, required: true
  attr :problem, :boolean, required: true

  # The threshold sits at mid-scale, so the marker never moves and the bar
  # reads the same way for both meters: how far from the line. Drawn as SVG
  # because widths are attributes there; the content security policy forbids
  # inline styles.
  defp meter(assigns) do
    ~H"""
    <div class="meter" id={@id}>
      <p class="meter-label">{@label}</p>
      <p class="meter-value">{@value}</p>
      <svg class={["meter-track", @problem && "meter-problem"]} aria-hidden="true" focusable="false">
        <rect class="meter-rail" width="100%" height="100%" rx="5" />
        <rect class="meter-fill" width={"#{@percent}%"} height="100%" rx="5" />
        <rect class="meter-mark" x="50%" width="2" height="100%" />
      </svg>
      <p class="muted">
        {@limit} ·
        <span class={@problem && "state state-queued"}>
          <.icon :if={@problem} name={:attention} /> {@verdict}
        </span>
      </p>
    </div>
    """
  end

  defp load_verdict(:ok), do: "below the limit"
  defp load_verdict(:over), do: "at or over the limit"
  defp load_verdict(:unknown), do: "reading unavailable"

  defp memory_verdict(:ok), do: "enough"
  defp memory_verdict(:under), do: "below the minimum"
  defp memory_verdict(:unknown), do: "reading unavailable"

  ## Events

  attr :events, :list, required: true
  attr :now, :integer, required: true

  def events_card(assigns) do
    assigns =
      assign(assigns, :recent, assigns.events |> Enum.reverse() |> Enum.take(@events_shown))

    ~H"""
    <section class="card" id="events" aria-labelledby="events-title">
      <header class="card-header">
        <h2 id="events-title">Recent events</h2>
        <p class="muted">newest first</p>
      </header>
      <p :if={@recent == []} class="empty">Nothing has happened yet.</p>
      <ul :if={@recent != []} class="events">
        <li :for={event <- @recent}>
          <span class="event-time">
            {Overview.format_duration(Overview.elapsed(event.at, @now))} ago
          </span>
          <span class={["event-kind", "event-#{event_tone(event.kind)}"]}>{event.kind}</span>
          <span class="event-text">
            <strong>{event.subject}</strong> <span class="muted">{event.detail}</span>
          </span>
        </li>
      </ul>
    </section>
    """
  end

  defp event_tone(kind) when kind in ~w(reap stale kill overcommit lock-timeout), do: "bad"
  defp event_tone(kind) when kind in ~w(queue park unpark lock-wait), do: "warn"
  defp event_tone(_kind), do: "plain"

  ## Small pieces

  attr :name, :atom,
    required: true,
    values: [:ok, :active, :idle, :waiting, :attention, :problem, :info]

  @doc """
  A 16-pixel status mark. Each meaning has its own outline, so states remain
  distinguishable in greyscale: tick, filled dot, hollow ring, clock, triangle,
  cross, and the letter i.
  """
  def icon(assigns) do
    ~H"""
    <svg class="icon" viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <%= case @name do %>
        <% :ok -> %>
          <circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5" />
          <path
            d="M5.2 8.3l1.9 1.9 3.7-4.1"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        <% :active -> %>
          <circle cx="8" cy="8" r="5" fill="currentColor" />
        <% :idle -> %>
          <circle cx="8" cy="8" r="5" fill="none" stroke="currentColor" stroke-width="1.5" />
        <% :waiting -> %>
          <circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5" />
          <path
            d="M8 4.6V8l2.3 1.5"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        <% :attention -> %>
          <path
            d="M8 2.2l6.3 11.1H1.7z"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linejoin="round"
          />
          <path d="M8 6.6v3.1" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
          <circle cx="8" cy="11.6" r=".85" fill="currentColor" />
        <% :problem -> %>
          <circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5" />
          <path
            d="M5.7 5.7l4.6 4.6M10.3 5.7l-4.6 4.6"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
          />
        <% :info -> %>
          <circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5" />
          <path d="M8 7.4v3.6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
          <circle cx="8" cy="5.1" r=".85" fill="currentColor" />
      <% end %>
    </svg>
    """
  end

  defp since(record, now), do: Overview.format_duration(Overview.elapsed(record.since, now))

  defp units(count), do: "#{count} #{plural(count, "unit")}"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp number(nil), do: "—"
  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
end
