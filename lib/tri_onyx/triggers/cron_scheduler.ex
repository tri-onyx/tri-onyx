defmodule TriOnyx.Triggers.CronScheduler do
  @moduledoc """
  Quantum-based cron scheduler for agent cron triggers.

  This module is a thin Quantum wrapper. Jobs are added and removed
  dynamically by `TriOnyx.Triggers.Scheduler` via `add_job/2` and
  `delete_job/1`.
  """

  use Quantum, otp_app: :tri_onyx
end
