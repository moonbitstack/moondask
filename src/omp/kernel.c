/*
 * Parallel kernels over flat arrays of doubles.
 *
 * One C source, three ways to run it, chosen at build time:
 *
 *   - `-fopenmp` (or MSVC's `/openmp`) defines `_OPENMP`, and the loops become
 *     `#pragma omp parallel for` with the schedule taken from the knobs at
 *     runtime, so changing the schedule needs no rebuild.
 *   - Without OpenMP, the same loops run on a thread pool of our own: pthreads
 *     on POSIX, the Win32 thread API on Windows.
 *   - With one thread, they run on the calling thread.
 *
 * The three paths compute the same values: the elementwise kernels are bit for
 * bit identical across them, and the reductions agree to rounding because they
 * add the same numbers in a different order. `moondask_parallel_backend` reports
 * which path was compiled in.
 *
 * The data pointers are the payload of a MoonBit array, so a length comes from
 * the object header rather than from a separate argument.
 */

/* cpu_set_t and pthread_setaffinity_np are Linux extensions, not POSIX. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "moonbit.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <unistd.h>
#endif

#if defined(_OPENMP)
#include <omp.h>
#define MOONDASK_BACKEND 2
#else
#if !defined(_WIN32)
#include <pthread.h>
#endif
#if defined(MOONDASK_SERIAL)
#define MOONDASK_BACKEND 0
#else
#define MOONDASK_BACKEND 1
#endif
#endif

#define MOONDASK_MAX_THREADS 256

/* Knobs. Zero means "decide for me": every core, and an even split. */
static int32_t g_threads = 0;
static int32_t g_schedule = 0; /* 0 static, 1 dynamic, 2 guided */
static int32_t g_chunk = 0;    /* 0 = a chunk size that keeps every core busy */
static int32_t g_affinity = 0; /* 0 none, 1 compact, 2 spread */

int32_t moondask_parallel_backend(void) { return MOONDASK_BACKEND; }

int32_t moondask_available_threads(void) {
#if defined(_WIN32)
  DWORD count = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  return count > 0 ? (int32_t)count : 1;
#elif defined(MOONDASK_SERIAL)
  return 1;
#else
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  return count > 0 ? (int32_t)count : 1;
#endif
}

void moondask_set_threads(int32_t threads) {
  if (threads < 1) {
    threads = moondask_available_threads();
  }
  if (threads > MOONDASK_MAX_THREADS) {
    threads = MOONDASK_MAX_THREADS;
  }
  g_threads = threads;
}

int32_t moondask_threads(void) {
  return g_threads > 0 ? g_threads : moondask_available_threads();
}

void moondask_set_schedule(int32_t schedule, int32_t chunk) {
  g_schedule = schedule < 0 ? 0 : (schedule > 2 ? 2 : schedule);
  g_chunk = chunk < 0 ? 0 : chunk;
}

void moondask_set_affinity(int32_t affinity) {
  g_affinity = affinity < 0 ? 0 : (affinity > 2 ? 2 : affinity);
}

/* xorshift64*, the same generator the portable kernels use. */
static uint64_t next_word(uint64_t state) {
  uint64_t x = state;
  x ^= x << 13;
  x ^= x >> 7;
  x ^= x << 17;
  return x;
}

static double unit_of(uint64_t word) {
  return (double)(word >> 11) / 9007199254740992.0;
}

#if defined(_OPENMP)
/* OpenMP 2.0 -- which is all the Microsoft compiler implements -- has no
   runtime schedule, so the schedule knob only takes effect where the runtime
   is 3.0 or newer. */
static void prepare_omp(void) {
  omp_set_num_threads(moondask_threads());
#if _OPENMP >= 200805
  omp_set_schedule(g_schedule == 0   ? omp_sched_static
                   : g_schedule == 1 ? omp_sched_dynamic
                                     : omp_sched_guided,
                   g_chunk);
#endif
}
#endif

/* ------------------------------------------------------------------------- */
/* The thread pool, used when OpenMP is not compiled in.                      */
/* ------------------------------------------------------------------------- */

/* A job covers [begin, end) of one array range, on the thread numbered `tid`. */
typedef void (*moondask_range_fn)(void *ctx, int32_t tid, int64_t begin,
                                  int64_t end);

#if !defined(_OPENMP)

typedef struct {
  moondask_range_fn fn;
  void *ctx;
  int64_t total;
  int64_t chunk; /* zero for a static split, else the dynamic chunk size */
  int64_t next;
  int32_t running;
  int32_t generation;
  int32_t threads;
  int32_t seen[MOONDASK_MAX_THREADS];
} moondask_pool_t;

static moondask_pool_t g_pool;

#if defined(_WIN32)
static CRITICAL_SECTION g_lock;
static CONDITION_VARIABLE g_wake;
static CONDITION_VARIABLE g_done;
static LONG g_started = 0;
#define LOCK() EnterCriticalSection(&g_lock)
#define UNLOCK() LeaveCriticalSection(&g_lock)
#define WAKE_ALL() WakeAllConditionVariable(&g_wake)
#define WAIT_WAKE() SleepConditionVariableCS(&g_wake, &g_lock, INFINITE)
#define WAIT_DONE() SleepConditionVariableCS(&g_done, &g_lock, INFINITE)
#define SIGNAL_DONE() WakeAllConditionVariable(&g_done)
#else
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_wake = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_done = PTHREAD_COND_INITIALIZER;
static int32_t g_started = 0;
#define LOCK() pthread_mutex_lock(&g_lock)
#define UNLOCK() pthread_mutex_unlock(&g_lock)
#define WAKE_ALL() pthread_cond_broadcast(&g_wake)
#define WAIT_WAKE() pthread_cond_wait(&g_wake, &g_lock)
#define WAIT_DONE() pthread_cond_wait(&g_done, &g_lock)
#define SIGNAL_DONE() pthread_cond_broadcast(&g_done)
#endif

/* Keep a thread on a core of its own, where the platform lets us say so. */
static void bind_thread(int32_t index, int32_t threads) {
  if (g_affinity == 0) {
    return;
  }
  int32_t total = moondask_available_threads();
  int32_t core = index < total ? index : index % total;
  if (g_affinity == 2 && threads > 0) {
    core = (index * (total / threads + 1)) % total;
  }
#if defined(_WIN32)
  SetThreadAffinityMask(GetCurrentThread(), (DWORD_PTR)1 << core);
#elif defined(__linux__)
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(core, &set);
  pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
#else
  (void)core;
#endif
}

static void run_ranges(moondask_pool_t *pool, int32_t tid) {
  int64_t total = pool->total;
  int64_t threads = pool->threads;
  if (pool->chunk > 0) {
    for (;;) {
      LOCK();
      int64_t begin = pool->next;
      int64_t end = begin + pool->chunk;
      if (end > total) {
        end = total;
      }
      if (begin < total) {
        pool->next = end;
      }
      UNLOCK();
      if (begin >= total) {
        return;
      }
      pool->fn(pool->ctx, tid, begin, end);
    }
  }
  int64_t begin = total * tid / threads;
  int64_t end = total * (tid + 1) / threads;
  if (begin < end) {
    pool->fn(pool->ctx, tid, begin, end);
  }
}

static
#if defined(_WIN32)
    DWORD WINAPI
#else
    void *
#endif
    worker_main(void *raw) {
  int32_t tid = (int32_t)(intptr_t)raw;
  bind_thread(tid, g_pool.threads);
  for (;;) {
    LOCK();
    while (g_pool.generation == g_pool.seen[tid]) {
      WAIT_WAKE();
    }
    g_pool.seen[tid] = g_pool.generation;
    int32_t participating = tid < g_pool.threads - 1;
    UNLOCK();
    if (participating) {
      run_ranges(&g_pool, tid);
      LOCK();
      g_pool.running--;
      if (g_pool.running == 0) {
        SIGNAL_DONE();
      }
      UNLOCK();
    }
  }
#if defined(_WIN32)
  return 0;
#else
  return NULL;
#endif
}

/* The Win32 lock and conditions start as memory, not as objects. */
static void ensure_lock(void) {
#if defined(_WIN32)
  static volatile LONG ready = 0;
  if (InterlockedCompareExchange(&ready, 1, 0) == 0) {
    InitializeCriticalSection(&g_lock);
    InitializeConditionVariable(&g_wake);
    InitializeConditionVariable(&g_done);
  }
#endif
}

/* Grow the pool to `threads - 1` workers the first time it is needed. */
static void ensure_pool(int32_t threads) {
  ensure_lock();
  LOCK();
  while (g_started < threads) {
    int32_t tid = g_started;
    g_pool.seen[tid] = g_pool.generation;
#if defined(_WIN32)
    HANDLE handle = CreateThread(NULL, 0, worker_main, (void *)(intptr_t)tid, 0,
                                 NULL);
    int started = handle != NULL;
    if (started) {
      CloseHandle(handle);
    }
#else
    pthread_t handle;
    int started =
        pthread_create(&handle, NULL, worker_main, (void *)(intptr_t)tid) == 0;
    if (started) {
      pthread_detach(handle);
    }
#endif
    if (!started) {
      break;
    }
    g_started++;
  }
  UNLOCK();
}

static void pool_run(moondask_range_fn fn, void *ctx, int64_t total) {
  ensure_lock();
  int32_t threads = moondask_threads();
  if (threads <= 1 || total <= 0) {
    fn(ctx, 0, 0, total);
    return;
  }
  int64_t chunk = 0;
  if (g_schedule != 0) {
    chunk = g_chunk;
    if (chunk <= 0) {
      chunk = (total + threads * 8 - 1) / (threads * 8);
      if (chunk < 1) {
        chunk = 1;
      }
    }
  }
  ensure_pool(threads - 1);
  LOCK();
  /* A pool that was grown for an earlier call may now be larger than this job
     wants; the extra workers wake up and stand aside. */
  int32_t participants = (g_started < threads - 1 ? g_started : threads - 1) + 1;
  g_pool.fn = fn;
  g_pool.ctx = ctx;
  g_pool.total = total;
  g_pool.chunk = chunk;
  g_pool.next = 0;
  g_pool.threads = participants;
  g_pool.running = participants - 1;
  g_pool.generation++;
  WAKE_ALL();
  UNLOCK();
  run_ranges(&g_pool, participants - 1); /* the caller takes the last share */
  LOCK();
  while (g_pool.running > 0) {
    WAIT_DONE();
  }
  UNLOCK();
}

#endif

/* ------------------------------------------------------------------------- */
/* Kernels                                                                    */
/* ------------------------------------------------------------------------- */

typedef struct {
  const double *a;
  const double *b;
  double *out;
  double alpha;
  uint64_t seed;
  double partial[MOONDASK_MAX_THREADS];
  int64_t hits[MOONDASK_MAX_THREADS];
} moondask_ctx_t;

#if !defined(_OPENMP)

static void sum_range(void *raw, int32_t tid, int64_t begin, int64_t end) {
  moondask_ctx_t *ctx = (moondask_ctx_t *)raw;
  double acc = 0;
  for (int64_t i = begin; i < end; i++) {
    acc += ctx->a[i];
  }
  ctx->partial[tid] += acc;
}

static void dot_range(void *raw, int32_t tid, int64_t begin, int64_t end) {
  moondask_ctx_t *ctx = (moondask_ctx_t *)raw;
  double acc = 0;
  for (int64_t i = begin; i < end; i++) {
    acc += ctx->a[i] * ctx->b[i];
  }
  ctx->partial[tid] += acc;
}

static void scale_range(void *raw, int32_t tid, int64_t begin, int64_t end) {
  moondask_ctx_t *ctx = (moondask_ctx_t *)raw;
  (void)tid;
  for (int64_t i = begin; i < end; i++) {
    ctx->out[i] = ctx->out[i] * ctx->alpha;
  }
}

static void axpy_range(void *raw, int32_t tid, int64_t begin, int64_t end) {
  moondask_ctx_t *ctx = (moondask_ctx_t *)raw;
  (void)tid;
  for (int64_t i = begin; i < end; i++) {
    ctx->out[i] = ctx->alpha * ctx->a[i] + ctx->out[i];
  }
}

static void pi_range(void *raw, int32_t tid, int64_t begin, int64_t end) {
  moondask_ctx_t *ctx = (moondask_ctx_t *)raw;
  int64_t hits = 0;
  /* draw i starts from base + i * phi, so a range can be cut anywhere and the
     count still adds up to the same total */
  for (int64_t i = begin; i < end; i++) {
    uint64_t state = ctx->seed + (uint64_t)i * 0x9E3779B97F4A7C15ULL;
    uint64_t first = next_word(state);
    uint64_t second = next_word(first);
    double x = unit_of(first);
    double y = unit_of(second);
    if (x * x + y * y <= 1.0) {
      hits++;
    }
  }
  ctx->hits[tid] += hits;
}

#endif

double moondask_sum(double *values) {
  int32_t len = Moonbit_array_length(values);
  if (len <= 0) {
    return 0.0;
  }
#if defined(_OPENMP)
  double acc = 0;
  int32_t i;
  prepare_omp();
#if _OPENMP >= 200805
#pragma omp parallel for schedule(runtime) reduction(+ : acc)
#else
#pragma omp parallel for reduction(+ : acc)
#endif
  for (i = 0; i < len; i++) {
    acc += values[i];
  }
  return acc;
#else
  moondask_ctx_t ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.a = values;
  pool_run(sum_range, &ctx, len);
  double acc = 0;
  for (int32_t i = 0; i < MOONDASK_MAX_THREADS; i++) {
    acc += ctx.partial[i];
  }
  return acc;
#endif
}

double moondask_dot(double *a, double *b) {
  int32_t len = Moonbit_array_length(a);
  int32_t len_b = Moonbit_array_length(b);
  if (len_b < len) {
    len = len_b;
  }
  if (len <= 0) {
    return 0.0;
  }
#if defined(_OPENMP)
  double acc = 0;
  int32_t i;
  prepare_omp();
#if _OPENMP >= 200805
#pragma omp parallel for schedule(runtime) reduction(+ : acc)
#else
#pragma omp parallel for reduction(+ : acc)
#endif
  for (i = 0; i < len; i++) {
    acc += a[i] * b[i];
  }
  return acc;
#else
  moondask_ctx_t ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.a = a;
  ctx.b = b;
  pool_run(dot_range, &ctx, len);
  double acc = 0;
  for (int32_t i = 0; i < MOONDASK_MAX_THREADS; i++) {
    acc += ctx.partial[i];
  }
  return acc;
#endif
}

void moondask_scale(double *values, double alpha) {
  int32_t len = Moonbit_array_length(values);
  if (len <= 0) {
    return;
  }
#if defined(_OPENMP)
  int32_t i;
  prepare_omp();
#if _OPENMP >= 200805
#pragma omp parallel for schedule(runtime)
#else
#pragma omp parallel for
#endif
  for (i = 0; i < len; i++) {
    values[i] = values[i] * alpha;
  }
#else
  moondask_ctx_t ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.out = values;
  ctx.alpha = alpha;
  pool_run(scale_range, &ctx, len);
#endif
}

void moondask_axpy(double alpha, double *x, double *y) {
  int32_t len = Moonbit_array_length(x);
  int32_t len_y = Moonbit_array_length(y);
  if (len_y < len) {
    len = len_y;
  }
  if (len <= 0) {
    return;
  }
#if defined(_OPENMP)
  int32_t i;
  prepare_omp();
#if _OPENMP >= 200805
#pragma omp parallel for schedule(runtime)
#else
#pragma omp parallel for
#endif
  for (i = 0; i < len; i++) {
    y[i] = alpha * x[i] + y[i];
  }
#else
  moondask_ctx_t ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.a = x;
  ctx.out = y;
  ctx.alpha = alpha;
  pool_run(axpy_range, &ctx, len);
#endif
}

double moondask_monte_carlo_pi(int64_t samples, uint64_t seed) {
  if (samples <= 0) {
    return 0.0;
  }
  uint64_t base = seed == 0 ? 0x9E3779B97F4A7C15ULL : seed;
#if defined(_OPENMP)
  int64_t hits = 0;
  int64_t i;
  prepare_omp();
#if _OPENMP >= 200805
#pragma omp parallel for schedule(runtime) reduction(+ : hits)
#else
#pragma omp parallel for reduction(+ : hits)
#endif
  for (i = 0; i < samples; i++) {
    uint64_t state = base + (uint64_t)i * 0x9E3779B97F4A7C15ULL;
    uint64_t first = next_word(state);
    uint64_t second = next_word(first);
    double x = unit_of(first);
    double y = unit_of(second);
    if (x * x + y * y <= 1.0) {
      hits++;
    }
  }
  return 4.0 * (double)hits / (double)samples;
#else
  moondask_ctx_t ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.seed = base;
  pool_run(pi_range, &ctx, samples);
  int64_t hits = 0;
  for (int32_t i = 0; i < MOONDASK_MAX_THREADS; i++) {
    hits += ctx.hits[i];
  }
  return 4.0 * (double)hits / (double)samples;
#endif
}
