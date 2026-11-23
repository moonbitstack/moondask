name = "moonbitstack/moondask"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondask"

license = "Apache-2.0"

keywords = [
  "parallel",
  "parallelism",
  "task graph",
  "dag",
  "executor",
  "scheduler",
  "map reduce",
  "reduction",
  "fork join",
  "worker",
  "workers",
  "multiprocess",
  "multiprocessing",
  "process pool",
  "thread pool",
  "openmp",
  "omp",
  "parallel for",
  "parallel reduce",
  "tbb",
  "affinity",
  "chunked array",
  "monte carlo",
  "cluster",
  "distributed",
  "dask",
  "ray",
  "mpi",
]

description = "Task graphs and the executors that run them: a deterministic local scheduler, worker processes that cross a JSON boundary, and OpenMP-style C kernels behind a thread pool."

source = "src"

import {
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonjson@0.5.1",
}
