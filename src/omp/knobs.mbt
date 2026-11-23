///|
/// How the work of a parallel loop is split between threads.
pub(all) enum Schedule {
  ///
  /// Cut the range into one block per thread before any of them starts. Cheapest
  /// when every element costs the same.
  Static
  ///
  /// Hand out blocks of `chunk` elements as threads come back for more, which
  /// evens out a range whose cost varies. A chunk of zero asks for a size that
  /// keeps every core busy without making the hand-outs cost more than the work.
  Dynamic(chunk~ : Int32)
  ///
  /// Like [`Dynamic`], with the blocks starting large and shrinking, so a range
  /// with a few expensive elements at the end does not leave one thread behind.
  Guided
}

///|
/// Whether threads are placed on particular cores, and how.
pub(all) enum Affinity {
  ///
  /// Leave placement to the operating system.
  None
  ///
  /// Number the threads onto the cores in order, so threads that share work sit
  /// close together.
  Compact
  ///
  /// Spread the threads across the machine, one core apart.
  Spread
}

///|
/// The three things a kernel can be told: how many threads, how the range is cut,
/// and where the threads run.
pub(all) struct Knobs {
  ///
  /// How many threads to use; zero means every core the machine reports.
  threads : Int32
  ///
  /// How the range is cut between them.
  schedule : Schedule
  ///
  /// Where the threads run.
  affinity : Affinity
}

///|
/// The defaults: every core, an even static split, and placement left to the
/// system.
pub let knobs : Knobs = { threads: 0, schedule: Static, affinity: None, }

///|
pub fn Knobs::new(
  threads~ : Int32 = 0,
  schedule~ : Schedule = Static,
  affinity~ : Affinity = None,
) -> Knobs {
  { threads, schedule, affinity, }
}

///|
/// The same knobs with a different thread count.
pub fn Knobs::with_threads(self : Knobs, threads : Int32) -> Knobs {
  { ..self, threads, }
}

///|
/// The same knobs with a different schedule.
pub fn Knobs::with_schedule(self : Knobs, schedule : Schedule) -> Knobs {
  { ..self, schedule, }
}

///|
/// The same knobs with a different placement.
pub fn Knobs::with_affinity(self : Knobs, affinity : Affinity) -> Knobs {
  { ..self, affinity, }
}

///|
/// Which of the three builds the kernels came from.
pub(all) enum Backend {
  ///
  /// One thread on the calling core.
  Serial
  ///
  /// Our own thread pool, over pthreads or the Win32 thread API.
  Threads
  ///
  /// Compiled with `-fopenmp`, so the loops are OpenMP's.
  Openmp
}
