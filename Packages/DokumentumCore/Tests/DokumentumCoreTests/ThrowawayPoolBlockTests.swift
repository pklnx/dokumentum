import Dispatch
import Testing

// Throwaway counter-proof for #174, never to be merged: blocks the only thread of a one-thread cooperative pool.
private func blockUntilSignalled(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

struct ThrowawayPoolBlockTests {
    @Test func aTestThatBlocksAPoolThread() async {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { semaphore.signal() }
        blockUntilSignalled(semaphore)
    }
}
