// MIT License
//
// Copyright (c) 2021 kprotty
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;

const zul = @import("zul");

const allocators = @import("allocators.zig");
const test_utils = @import("test_utils.zig");

pub const ThreadPool = @This();

stack_size: u32,
max_threads: u32,
sync: Atomic(u32) = Atomic(u32).init(@bitCast(Sync{})),
idle_event: Event = .{},
join_event: Event = .{},
run_queue: Node.Queue = .{},
threads: Atomic(?*Thread) = Atomic(?*Thread).init(null),

const Sync = packed struct {
    /// Tracks the number of threads not searching for Tasks
    idle: u14 = 0,
    /// Tracks the number of threads spawned
    spawned: u14 = 0,
    /// What you see is what you get
    unused: bool = false,
    /// Used to not miss notifications while state = waking
    notified: bool = false,
    /// The current state of the thread pool
    state: enum(u2) {
        /// A notification can be issued to wake up a sleeping as the "waking thread".
        pending = 0,
        /// The state was notifiied with a signal. A thread is woken up.
        /// The first thread to transition to `waking` becomes the "waking thread".
        signaled,
        /// There is a "waking thread" among us.
        /// No other thread should be woken up until the waking thread transitions the state.
        waking,
        /// The thread pool was terminated. Start decremented `spawned` so that it can be joined.
        shutdown,
    } = .pending,
};

/// Configuration options for the thread pool.
/// TODO: add CPU core affinity?
pub const Config = struct {
    stack_size: u32 = (std.Thread.SpawnConfig{}).stack_size,
    max_threads: u32,
};

/// Statically initialize the thread pool using the configuration.
pub fn init(config: Config) ThreadPool {
    return .{
        .stack_size = @max(1, config.stack_size),
        .max_threads = @max(1, config.max_threads),
    };
}

/// Wait for a thread to call shutdown() on the thread pool and kill the worker threads.
pub fn deinit(self: *ThreadPool) void {
    self.join();
    self.* = undefined;
}

/// A Task represents the unit of Work / Job / Execution that the ThreadPool schedules.
/// The user provides a `callback` which is invoked when the *Task can run on a thread.
pub const Task = struct {
    node: Node = .{},
    ptr: *anyopaque,
    callback: *const fn (*anyopaque) void,
};

/// An unordered collection of Tasks which can be submitted for scheduling as a group.
pub const Batch = struct {
    len: usize = 0,
    head: ?*Task = null,
    tail: ?*Task = null,

    /// Create a batch from a single task.
    pub fn from(task: *Task) Batch {
        return Batch{
            .len = 1,
            .head = task,
            .tail = task,
        };
    }

    /// Another batch into this one, taking ownership of its tasks.
    pub fn push(self: *Batch, batch: Batch) void {
        if (batch.len == 0) return;
        if (self.len == 0) {
            self.* = batch;
        } else {
            self.tail.?.node.next = if (batch.head) |h| &h.node else null;
            self.tail = batch.tail;
            self.len += batch.len;
        }
    }
};

/// Schedule a batch of tasks to be executed by some thread on the thread pool.
pub fn schedule(self: *ThreadPool, batch: Batch) void {
    // Sanity check
    if (batch.len == 0) {
        return;
    }

    // Extract out the Node's from the Tasks
    var list = Node.List{
        .head = &batch.head.?.node,
        .tail = &batch.tail.?.node,
    };

    // Push the task Nodes to the most approriate queue
    if (Thread.current) |thread| {
        thread.run_buffer.push(&list) catch thread.run_queue.push(list);
    } else {
        self.run_queue.push(list);
    }

    // Try to notify a thread
    const is_waking = false;
    return self.notify(is_waking);
}

inline fn notify(self: *ThreadPool, is_waking: bool) void {
    // Fast path to check the Sync state to avoid calling into notifySlow().
    // If we're waking, then we need to update the state regardless
    if (!is_waking) {
        const sync: Sync = @bitCast(self.sync.load(.monotonic));
        if (sync.notified) {
            return;
        }
    }

    return self.notifySlow(is_waking);
}

noinline fn notifySlow(self: *ThreadPool, is_waking: bool) void {
    var sync: Sync = @bitCast(self.sync.load(.monotonic));
    while (sync.state != .shutdown) {
        const can_wake = is_waking or (sync.state == .pending);
        if (is_waking) {
            assert(sync.state == .waking);
        }

        var new_sync = sync;
        new_sync.notified = true;
        if (can_wake and sync.idle > 0) { // wake up an idle thread
            new_sync.state = .signaled;
        } else if (can_wake and sync.spawned < self.max_threads) { // spawn a new thread
            new_sync.state = .signaled;
            new_sync.spawned += 1;
        } else if (is_waking) { // no other thread to pass on "waking" status
            new_sync.state = .pending;
        } else if (sync.notified) { // nothing to update
            return;
        }

        // Release barrier synchronizes with Acquire in wait()
        // to ensure pushes to run queues happen before observing a posted notification.
        sync = @bitCast(self.sync.cmpxchgWeak(
            @bitCast(sync),
            @bitCast(new_sync),
            .release,
            .monotonic,
        ) orelse {
            // We signaled to notify an idle thread
            if (can_wake and sync.idle > 0) {
                return self.idle_event.notify();
            }

            // We signaled to spawn a new thread
            if (can_wake and sync.spawned < self.max_threads) {
                const spawn_config = std.Thread.SpawnConfig{ .stack_size = self.stack_size };
                const thread = std.Thread.spawn(spawn_config, Thread.run, .{self}) catch return self.unregister(null);
                return thread.detach();
            }

            return;
        });
    }
}

noinline fn wait(self: *ThreadPool, _is_waking: bool) error{Shutdown}!bool {
    var is_idle = false;
    var is_waking = _is_waking;
    var sync: Sync = @bitCast(self.sync.load(.monotonic));

    while (true) {
        if (sync.state == .shutdown) return error.Shutdown;
        if (is_waking) assert(sync.state == .waking);

        // Consume a notification made by notify().
        if (sync.notified) {
            var new_sync = sync;
            new_sync.notified = false;
            if (is_idle)
                new_sync.idle -= 1;
            if (sync.state == .signaled)
                new_sync.state = .waking;

            // Acquire barrier synchronizes with notify()
            // to ensure that pushes to run queue are observed after wait() returns.
            sync = @bitCast(self.sync.cmpxchgWeak(
                @bitCast(sync),
                @bitCast(new_sync),
                .acquire,
                .monotonic,
            ) orelse {
                return is_waking or (sync.state == .signaled);
            });

            // No notification to consume.
            // Mark this thread as idle before sleeping on the idle_event.
        } else if (!is_idle) {
            var new_sync = sync;
            new_sync.idle += 1;
            if (is_waking)
                new_sync.state = .pending;

            sync = @bitCast(self.sync.cmpxchgWeak(
                @bitCast(sync),
                @bitCast(new_sync),
                .monotonic,
                .monotonic,
            ) orelse {
                is_waking = false;
                is_idle = true;
                continue;
            });

            // Wait for a signal by either notify() or shutdown() without wasting cpu cycles.
            // TODO: Add I/O polling here.
        } else {
            self.idle_event.wait();
            sync = @bitCast(self.sync.load(.monotonic));
        }
    }
}

/// Marks the thread pool as shutdown
pub noinline fn shutdown(self: *ThreadPool) void {
    var sync: Sync = @bitCast(self.sync.load(.monotonic));
    while (sync.state != .shutdown) {
        var new_sync = sync;
        new_sync.notified = true;
        new_sync.state = .shutdown;
        new_sync.idle = 0;

        // Full barrier to synchronize with both wait() and notify()
        sync = @bitCast(self.sync.cmpxchgWeak(
            @bitCast(sync),
            @bitCast(new_sync),
            .acq_rel,
            .monotonic,
        ) orelse {
            // Wake up any threads sleeping on the idle_event.
            // TODO: I/O polling notification here.
            if (sync.idle > 0) self.idle_event.shutdown();
            return;
        });
    }
}

fn register(noalias self: *ThreadPool, noalias thread: *Thread) void {
    // Push the thread onto the threads stack in a lock-free manner.
    var threads = self.threads.load(.monotonic);
    while (true) {
        thread.next = threads;
        threads = self.threads.cmpxchgWeak(
            threads,
            thread,
            .release,
            .monotonic,
        ) orelse break;
    }
}

fn unregister(noalias self: *ThreadPool, noalias maybe_thread: ?*Thread) void {
    // Un-spawn one thread, either due to a failed OS thread spawning or the thread is exitting.
    const one_spawned: u32 = @bitCast(Sync{ .spawned = 1 });
    const sync: Sync = @bitCast(self.sync.fetchSub(one_spawned, .release));
    assert(sync.spawned > 0);

    // The last thread to exit must wake up the thread pool join()er
    // who will start the chain to shutdown all the threads.
    if (sync.state == .shutdown and sync.spawned == 1) {
        self.join_event.notify();
    }

    // If this is a thread pool thread, wait for a shutdown signal by the thread pool join()er.
    const thread = maybe_thread orelse return;
    thread.join_event.wait();

    // After receiving the shutdown signal, shutdown the next thread in the pool.
    // We have to do that without touching the thread pool itself since it's memory is invalidated by now.
    // So just follow our .next link.
    const next_thread = thread.next orelse return;
    next_thread.join_event.notify();
}

fn join(self: *ThreadPool) void {
    // Wait for the thread pool to be shutdown() then for all threads to enter a joinable state
    self.join_event.wait();
    const sync: Sync = @bitCast(self.sync.load(.monotonic));
    assert(sync.state == .shutdown);
    assert(sync.spawned == 0);

    // If there are threads, start off the chain sending it the shutdown signal.
    // The thread receives the shutdown signal and sends it to the next thread, and the next..
    const thread = self.threads.load(.acquire) orelse return;
    thread.join_event.notify();
}

const Thread = struct {
    next: ?*Thread = null,
    target: ?*Thread = null,
    join_event: Event = .{},
    run_queue: Node.Queue = .{},
    run_buffer: Node.Buffer = .{},

    threadlocal var current: ?*Thread = null;

    /// Thread entry point which runs a worker for the ThreadPool
    fn run(thread_pool: *ThreadPool) void {
        var self = Thread{};
        current = &self;

        thread_pool.register(&self);
        defer thread_pool.unregister(&self);

        var is_waking = false;
        while (true) {
            is_waking = thread_pool.wait(is_waking) catch return;

            while (self.pop(thread_pool)) |result| {
                if (result.pushed or is_waking)
                    thread_pool.notify(is_waking);
                is_waking = false;

                const task: *Task = @fieldParentPtr("node", result.node);
                (task.callback)(task.ptr);
            }
        }
    }

    /// Try to dequeue a Node/Task from the ThreadPool.
    /// Spurious reports of dequeue() returning empty are allowed.
    fn pop(noalias self: *Thread, noalias thread_pool: *ThreadPool) ?Node.Buffer.Stole {
        // Check our local buffer first
        if (self.run_buffer.pop()) |node| {
            return Node.Buffer.Stole{
                .node = node,
                .pushed = false,
            };
        }

        // Then check our local queue
        if (self.run_buffer.consume(&self.run_queue)) |stole| {
            return stole;
        }

        // Then the global queue
        if (self.run_buffer.consume(&thread_pool.run_queue)) |stole| {
            return stole;
        }

        // TODO: add optimistic I/O polling here

        // Then try work stealing from other threads
        // var num_threads: u32 = @bitCast(Sync, thread_pool.sync.load(.Monotonic)).spawned;
        const sync: Sync = @bitCast(thread_pool.sync.load(.monotonic));
        var num_threads: u32 = sync.spawned;
        while (num_threads > 0) : (num_threads -= 1) {
            // Traverse the stack of registered threads on the thread pool
            const target = self.target orelse thread_pool.threads.load(.acquire) orelse unreachable;
            self.target = target.next;

            // Try to steal from their queue first to avoid contention (the target steal's from queue last).
            if (self.run_buffer.consume(&target.run_queue)) |stole| {
                return stole;
            }

            // Skip stealing from the buffer if we're the target.
            // We still steal from our own queue above given it may have just been locked the first time we tried.
            if (target == self) {
                continue;
            }

            // Steal from the buffer of a remote thread as a last resort
            if (self.run_buffer.steal(&target.run_buffer)) |stole| {
                return stole;
            }
        }

        return null;
    }
};

/// An event which stores 1 semaphore token and is multi-threaded safe.
/// The event can be shutdown(), waking up all wait()ing threads and
/// making subsequent wait()'s return immediately.
const Event = struct {
    state: Atomic(u32) = Atomic(u32).init(EMPTY),

    const EMPTY = 0;
    const WAITING = 1;
    const NOTIFIED = 2;
    const SHUTDOWN = 3;

    /// Wait for and consume a notification
    /// or wait for the event to be shutdown entirely
    noinline fn wait(self: *Event) void {
        var acquire_with: u32 = EMPTY;
        var state = self.state.load(.monotonic);

        while (true) {
            // If we're shutdown then exit early.
            // Acquire barrier to ensure operations before the shutdown() are seen after the wait().
            // Shutdown is rare so it's better to have an Acquire barrier here instead of on CAS failure + load which are common.
            if (state == SHUTDOWN) {
                // std.atomic.fence(.acquire);
                return;
            }

            // Consume a notification when it pops up.
            // Acquire barrier to ensure operations before the notify() appear after the wait().
            if (state == NOTIFIED) {
                state = self.state.cmpxchgWeak(
                    state,
                    acquire_with,
                    .acquire,
                    .monotonic,
                ) orelse return;
                continue;
            }

            // There is no notification to consume, we should wait on the event by ensuring its WAITING.
            if (state != WAITING) blk: {
                state = self.state.cmpxchgWeak(
                    state,
                    WAITING,
                    .monotonic,
                    .monotonic,
                ) orelse break :blk;
                continue;
            }

            // Wait on the event until a notify() or shutdown().
            // If we wake up to a notification, we must acquire it with WAITING instead of EMPTY
            // since there may be other threads sleeping on the Futex who haven't been woken up yet.
            //
            // Acquiring to WAITING will make the next notify() or shutdown() wake a sleeping futex thread
            // who will either exit on SHUTDOWN or acquire with WAITING again, ensuring all threads are awoken.
            // This unfortunately results in the last notify() or shutdown() doing an extra futex wake but that's fine.
            std.Thread.Futex.wait(&self.state, WAITING);
            state = self.state.load(.monotonic);
            acquire_with = WAITING;
        }
    }

    /// Post a notification to the event if it doesn't have one already
    /// then wake up a waiting thread if there is one as well.
    fn notify(self: *Event) void {
        return self.wake(NOTIFIED, 1);
    }

    /// Marks the event as shutdown, making all future wait()'s return immediately.
    /// Then wakes up any threads currently waiting on the Event.
    fn shutdown(self: *Event) void {
        return self.wake(SHUTDOWN, std.math.maxInt(u32));
    }

    fn wake(self: *Event, release_with: u32, wake_threads: u32) void {
        // Update the Event to notifty it with the new `release_with` state (either NOTIFIED or SHUTDOWN).
        // Release barrier to ensure any operations before this are this to happen before the wait() in the other threads.
        const state = self.state.swap(release_with, .release);

        // Only wake threads sleeping in futex if the state is WAITING.
        // Avoids unnecessary wake ups.
        if (state == WAITING) {
            std.Thread.Futex.wake(&self.state, wake_threads);
        }
    }
};

/// Linked list intrusive memory node and lock-free data structures to operate with it
const Node = struct {
    next: ?*Node = null,

    /// A linked list of Nodes
    const List = struct {
        head: *Node,
        tail: *Node,
    };

    /// An unbounded multi-producer-(non blocking)-multi-consumer queue of Node pointers.
    const Queue = struct {
        stack: Atomic(usize) = Atomic(usize).init(0),
        cache: ?*Node = null,

        const HAS_CACHE: usize = 0b01;
        const IS_CONSUMING: usize = 0b10;
        const PTR_MASK: usize = ~(HAS_CACHE | IS_CONSUMING);

        comptime {
            assert(@alignOf(Node) >= ((IS_CONSUMING | HAS_CACHE) + 1));
        }

        fn push(noalias self: *Queue, list: List) void {
            var stack = self.stack.load(.monotonic);
            while (true) {
                // Attach the list to the stack (pt. 1)
                list.tail.next = @ptrFromInt(stack & PTR_MASK);

                // Update the stack with the list (pt. 2).
                // Don't change the HAS_CACHE and IS_CONSUMING bits of the consumer.
                var new_stack = @intFromPtr(list.head);
                assert(new_stack & ~PTR_MASK == 0);
                new_stack |= (stack & ~PTR_MASK);

                // Push to the stack with a release barrier for the consumer to see the proper list links.
                stack = self.stack.cmpxchgWeak(
                    stack,
                    new_stack,
                    .release,
                    .monotonic,
                ) orelse break;
            }
        }

        fn tryAcquireConsumer(self: *Queue) error{ Empty, Contended }!?*Node {
            var stack = self.stack.load(.monotonic);
            while (true) {
                if (stack & IS_CONSUMING != 0)
                    return error.Contended; // The queue already has a consumer.
                if (stack & (HAS_CACHE | PTR_MASK) == 0)
                    return error.Empty; // The queue is empty when there's nothing cached and nothing in the stack.

                // When we acquire the consumer, also consume the pushed stack if the cache is empty.
                var new_stack = stack | HAS_CACHE | IS_CONSUMING;
                if (stack & HAS_CACHE == 0) {
                    assert(stack & PTR_MASK != 0);
                    new_stack &= ~PTR_MASK;
                }

                // Acquire barrier on getting the consumer to see cache/Node updates done by previous consumers
                // and to ensure our cache/Node updates in pop() happen after that of previous consumers.
                stack = self.stack.cmpxchgWeak(
                    stack,
                    new_stack,
                    .acquire,
                    .monotonic,
                    // ) orelse return self.cache orelse @intToPtr(*Node, stack & PTR_MASK);
                ) orelse return self.cache orelse @ptrFromInt(stack & PTR_MASK);
            }
        }

        fn releaseConsumer(noalias self: *Queue, noalias consumer: ?*Node) void {
            // Stop consuming and remove the HAS_CACHE bit as well if the consumer's cache is empty.
            // When HAS_CACHE bit is zeroed, the next consumer will acquire the pushed stack nodes.
            var remove = IS_CONSUMING;
            if (consumer == null)
                remove |= HAS_CACHE;

            // Release the consumer with a release barrier to ensure cache/node accesses
            // happen before the consumer was released and before the next consumer starts using the cache.
            self.cache = consumer;
            const stack = self.stack.fetchSub(remove, .release);
            assert(stack & remove != 0);
        }

        fn pop(noalias self: *Queue, noalias consumer_ref: *?*Node) ?*Node {
            // Check the consumer cache (fast path)
            if (consumer_ref.*) |node| {
                consumer_ref.* = node.next;
                return node;
            }

            // Load the stack to see if there was anything pushed that we could grab.
            var stack = self.stack.load(.monotonic);
            assert(stack & IS_CONSUMING != 0);
            if (stack & PTR_MASK == 0) {
                return null;
            }

            // Nodes have been pushed to the stack, grab then with an Acquire barrier to see the Node links.
            stack = self.stack.swap(HAS_CACHE | IS_CONSUMING, .acquire);
            assert(stack & IS_CONSUMING != 0);
            assert(stack & PTR_MASK != 0);

            const node: *Node = @ptrFromInt(stack & PTR_MASK);
            consumer_ref.* = node.next;
            return node;
        }
    };

    /// A bounded single-producer, multi-consumer ring buffer for node pointers.
    const Buffer = struct {
        head: Atomic(Index) = Atomic(Index).init(0),
        tail: Atomic(Index) = Atomic(Index).init(0),
        array: [capacity]Atomic(*Node) = undefined,

        const Index = u32;
        const capacity = 256; // Appears to be a pretty good trade-off in space vs contended throughput
        comptime {
            assert(std.math.maxInt(Index) >= capacity);
            assert(std.math.isPowerOfTwo(capacity));
        }

        fn push(noalias self: *Buffer, noalias list: *List) error{Overflow}!void {
            var head = self.head.load(.monotonic);
            var tail = self.tail.load(.unordered); // we're the only thread that can change this

            while (true) {
                var size = tail -% head;
                assert(size <= capacity);

                // Push nodes from the list to the buffer if it's not empty..
                if (size < capacity) {
                    var nodes: ?*Node = list.head;
                    while (size < capacity) : (size += 1) {
                        const node = nodes orelse break;
                        nodes = node.next;

                        // Array written atomically with weakest ordering since it could be getting atomically read by steal().
                        self.array[tail % capacity].store(node, .unordered);
                        tail +%= 1;
                    }

                    // Release barrier synchronizes with Acquire loads for steal()ers to see the array writes.
                    self.tail.store(tail, .release);

                    // Update the list with the nodes we pushed to the buffer and try again if there's more.
                    list.head = nodes orelse return;
                    std.atomic.spinLoopHint();
                    head = self.head.load(.monotonic);
                    continue;
                }

                // Try to steal/overflow half of the tasks in the buffer to make room for future push()es.
                // Migrating half amortizes the cost of stealing while requiring future pops to still use the buffer.
                // Acquire barrier to ensure the linked list creation after the steal only happens after we succesfully steal.
                var migrate = size / 2;
                head = self.head.cmpxchgWeak(
                    head,
                    head +% migrate,
                    .acquire,
                    .monotonic,
                ) orelse {
                    // Link the migrated Nodes together
                    const first = self.array[head % capacity].load(.unordered);
                    while (migrate > 0) : (migrate -= 1) {
                        const prev = self.array[head % capacity].load(.unordered);
                        head +%= 1;
                        prev.next = self.array[head % capacity].load(.unordered);
                    }

                    // Append the list that was supposed to be pushed to the end of the migrated Nodes
                    const last = self.array[(head -% 1) % capacity].load(.unordered);
                    last.next = list.head;
                    list.tail.next = null;

                    // Return the migrated nodes + the original list as overflowed
                    list.head = first;
                    return error.Overflow;
                };
            }
        }

        fn pop(self: *Buffer) ?*Node {
            var head = self.head.load(.monotonic);
            const tail = self.tail.load(.unordered); // we're the only thread that can change this

            while (true) {
                // Quick sanity check and return null when not empty
                const size = tail -% head;
                assert(size <= capacity);
                if (size == 0) {
                    return null;
                }

                // Dequeue with an acquire barrier to ensure any writes done to the Node
                // only happen after we succesfully claim it from the array.
                head = self.head.cmpxchgWeak(
                    head,
                    head +% 1,
                    .acquire,
                    .monotonic,
                ) orelse return self.array[head % capacity].load(.unordered);
            }
        }

        const Stole = struct {
            node: *Node,
            pushed: bool,
        };

        fn consume(noalias self: *Buffer, noalias queue: *Queue) ?Stole {
            var consumer = queue.tryAcquireConsumer() catch return null;
            defer queue.releaseConsumer(consumer);

            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.unordered); // we're the only thread that can change this

            const size = tail -% head;
            assert(size <= capacity);
            assert(size == 0); // we should only be consuming if our array is empty

            // Pop nodes from the queue and push them to our array.
            // Atomic stores to the array as steal() threads may be atomically reading from it.
            var pushed: Index = 0;
            while (pushed < capacity) : (pushed += 1) {
                const node = queue.pop(&consumer) orelse break;
                self.array[(tail +% pushed) % capacity].store(node, .unordered);
            }

            // We will be returning one node that we stole from the queue.
            // Get an extra, and if that's not possible, take one from our array.
            const node = queue.pop(&consumer) orelse blk: {
                if (pushed == 0) return null;
                pushed -= 1;
                break :blk self.array[(tail +% pushed) % capacity].load(.unordered);
            };

            // Update the array tail with the nodes we pushed to it.
            // Release barrier to synchronize with Acquire barrier in steal()'s to see the written array Nodes.
            if (pushed > 0) self.tail.store(tail +% pushed, .release);
            return Stole{
                .node = node,
                .pushed = pushed > 0,
            };
        }

        fn steal(noalias self: *Buffer, noalias buffer: *Buffer) ?Stole {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.unordered); // we're the only thread that can change this

            const size = tail -% head;
            assert(size <= capacity);
            assert(size == 0); // we should only be stealing if our array is empty

            while (true) : (std.atomic.spinLoopHint()) {
                const buffer_head = buffer.head.load(.acquire);
                const buffer_tail = buffer.tail.load(.acquire);

                // Overly large size indicates the the tail was updated a lot after the head was loaded.
                // Reload both and try again.
                const buffer_size = buffer_tail -% buffer_head;
                if (buffer_size > capacity) {
                    continue;
                }

                // Try to steal half (divCeil) to amortize the cost of stealing from other threads.
                const steal_size = buffer_size - (buffer_size / 2);
                if (steal_size == 0) {
                    return null;
                }

                // Copy the nodes we will steal from the target's array to our own.
                // Atomically load from the target buffer array as it may be pushing and atomically storing to it.
                // Atomic store to our array as other steal() threads may be atomically loading from it as above.
                var i: Index = 0;
                while (i < steal_size) : (i += 1) {
                    const node = buffer.array[(buffer_head +% i) % capacity].load(.unordered);
                    self.array[(tail +% i) % capacity].store(node, .unordered);
                }

                // Try to commit the steal from the target buffer using:
                // - an Acquire barrier to ensure that we only interact with the stolen Nodes after the steal was committed.
                // - a Release barrier to ensure that the Nodes are copied above prior to the committing of the steal
                //   because if they're copied after the steal, the could be getting rewritten by the target's push().
                _ = buffer.head.cmpxchgStrong(
                    buffer_head,
                    buffer_head +% steal_size,
                    .acq_rel,
                    .monotonic,
                ) orelse {
                    // Pop one from the nodes we stole as we'll be returning it
                    const pushed = steal_size - 1;
                    const node = self.array[(tail +% pushed) % capacity].load(.unordered);

                    // Update the array tail with the nodes we pushed to it.
                    // Release barrier to synchronize with Acquire barrier in steal()'s to see the written array Nodes.
                    if (pushed > 0) self.tail.store(tail +% pushed, .release);
                    return Stole{
                        .node = node,
                        .pushed = pushed > 0,
                    };
                };
            }
        }
    };
};

const testTaskWait = 50;
const testIterations = 1000;

fn runThreadpoolTest(testNumThreads: u32) !void {
    const TestTask = struct {
        const Self = @This();

        counter: *std.atomic.Value(usize),
        task_id: usize,
        task: ?ThreadPool.Task,

        fn init(counter: *std.atomic.Value(usize), task_id: usize) Self {
            return .{ .counter = counter, .task_id = task_id, .task = null };
        }

        fn getTask(self: *Self) *ThreadPool.Task {
            if (self.task == null) {
                self.task = .{ .ptr = self, .callback = onSchedule };
            }
            return &self.task.?;
        }

        fn onSchedule(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            std.time.sleep(testTaskWait);
            // std.debug.print("task done: {}\n", .{self.task_id});
            _ = self.counter.fetchAdd(1, .acquire);
        }

        fn getBatch(self: *Self) ThreadPool.Batch {
            return ThreadPool.Batch.from(self.getTask());
        }
    };

    var infa = try allocators.IncreaseNeverFreeAllocator.init(std.heap.smp_allocator, 8 * allocators.kb_to_bytes, allocators.mb_to_bytes);
    defer infa.deinit();
    const alloc = infa.allocator();

    var tp = ThreadPool.init(.{ .stack_size = 1000, .max_threads = testNumThreads });
    defer tp.deinit();

    var counter = std.atomic.Value(usize).init(0);

    var total_tasks: usize = 0;
    for (0..testIterations) |i| {
        var ptr = try alloc.create(TestTask);
        ptr.* = TestTask.init(&counter, i);
        tp.schedule(ptr.getBatch());
        total_tasks += 1;
    }

    while (counter.load(.acquire) < total_tasks) {}
    tp.shutdown();
}

test "test thread pool" {
    try test_utils.is_regular();
    try runThreadpoolTest(32);
}

fn benchmarkThreadpoolLow(_: std.mem.Allocator, _: *std.time.Timer) !void {
    try runThreadpoolTest(16);
}

fn benchmarkThreadpoolHigh(_: std.mem.Allocator, _: *std.time.Timer) !void {
    try runThreadpoolTest(256);
}

fn someTestTask(counter: *std.atomic.Value(usize), task_id: usize) void {
    _ = task_id;
    std.time.sleep(testTaskWait);
    _ = counter.fetchAdd(1, .acquire);
}

fn runZulThreadpool(testNumThreads: u32) !void {
    var infa = try allocators.IncreaseNeverFreeAllocator.init(std.heap.smp_allocator, 8 * allocators.kb_to_bytes, allocators.mb_to_bytes);
    defer infa.deinit();
    const alloc = infa.allocator();

    var tp = try zul.ThreadPool(someTestTask).init(alloc, .{ .count = testNumThreads, .backlog = testIterations * 2 });
    defer tp.deinit(alloc);

    var counter = std.atomic.Value(usize).init(0);

    var total_tasks: usize = 0;
    for (0..testIterations) |i| {
        try tp.spawn(.{ &counter, i });
        total_tasks += 1;
    }
}

fn benchmarkZulThreadpoolLow(_: std.mem.Allocator, _: *std.time.Timer) !void {
    try runZulThreadpool(16);
}
fn benchmarkZulThreadpoolHigh(_: std.mem.Allocator, _: *std.time.Timer) !void {
    try runZulThreadpool(256);
}

test "benchmark threadpools" {
    try test_utils.is_benchmark("benchmark threadpools");
    (try zul.benchmark.run(benchmarkZulThreadpoolLow, test_utils.default_benchmark_options)).print("benchmark Zul Threadpool low contention");
    (try zul.benchmark.run(benchmarkZulThreadpoolHigh, test_utils.default_benchmark_options)).print("benchmark Zul Threadpool high contention");
    (try zul.benchmark.run(benchmarkThreadpoolLow, test_utils.default_benchmark_options)).print("benchmark Threadpool low contention");
    (try zul.benchmark.run(benchmarkThreadpoolHigh, test_utils.default_benchmark_options)).print("benchmark Threadpool high contention");
}
