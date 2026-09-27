import Foundation
import MacLensCore

/// What the sampler should collect, derived from what is on screen.
struct SampleMode: Equatable {
    var interval: Double = 5
    /// Seconds between /bin/ps runs for other users' processes (0 = every tick).
    var foreignEvery: Double = 30
    var ports = false
    var temps = false
    /// Seconds between temperature reads when `temps` is off (keeps dashboard history continuous).
    var tempsEvery: Double = 30
    var runawayCPU: Double = 90
    var runawayMinutes: Double = 5
}

struct SampleOutput {
    var processes: [ProcSample]
    var battery: BatteryInfo
    var thermalState: ProcessInfo.ThermalState
    var thermal: ThermalSummary?
    var assertions: [SleepAssertion]
    var ports: [PortEntry]?
    var wattsPerCore: Double
    /// Processes above the runaway CPU threshold for the configured duration.
    var runaway: [ProcSample]
    var cpuLoad: Double?
    var memory: SystemStats.Memory?
    var disk: SystemStats.Disk?
    var health: BatteryHealth?
}

/// Runs all sampling on one background queue with a coalescing timer.
final class Engine: @unchecked Sendable {
    private let q = DispatchQueue(label: "maclens.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var mode = SampleMode()
    private let sampler = ProcessSampler()
    private lazy var smc = SMC()
    private lazy var hid = HIDTemperatures()
    private var lastPorts: [PortEntry]?
    private let stats = SystemStats()
    private var lastTemps = 0.0
    private var lastThermal: ThermalSummary?
    private var lastDisk: (t: Double, d: SystemStats.Disk?) = (0, nil)
    private var lastHealth: (t: Double, h: BatteryHealth?) = (-1e9, nil)
    var onSample: ((SampleOutput) -> Void)?

    func start(_ m: SampleMode) {
        q.async { self.mode = m; self.schedule(); self.tick() }
    }

    func setMode(_ m: SampleMode) {
        q.async {
            let old = self.mode
            guard m != old else { return }
            self.mode = m
            if m.interval != old.interval { self.schedule() }
            // Newly visible data (e.g. switched to Ports) should appear immediately.
            if (m.ports && !old.ports) || (m.temps && !old.temps) || m.foreignEvery < old.foreignEvery { self.tick() }
        }
    }

    func tickNow() { q.async { self.tick() } }

    func refreshPortsNow(_ done: @escaping ([PortEntry]) -> Void) {
        q.async {
            let p = PortScanner.listening()
            self.lastPorts = p
            DispatchQueue.main.async { done(p) }
        }
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        let iv = mode.interval
        t.schedule(deadline: .now() + iv, repeating: iv, leeway: .milliseconds(Int(iv * 200))) // 20% leeway lets macOS coalesce wakeups
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = monotonicSeconds()
        let includeForeign = now - sampler.lastForeignRefresh >= max(0, mode.foreignEvery - 0.25)
        let procs = sampler.sample(includeForeign: includeForeign)
        var thermal: ThermalSummary?
        if mode.temps || now - lastTemps >= mode.tempsEvery {
            thermal = ThermalSummary.summarize(hid?.read() ?? [], fans: smc?.fanRPMs() ?? [])
            lastTemps = now
            lastThermal = thermal
        }
        if now - lastDisk.t >= 60 { lastDisk = (now, SystemStats.disk()) }
        if now - lastHealth.t >= 600 { lastHealth = (now, PowerReader.health()) } // health changes over weeks; 10 min is plenty
        if mode.ports { lastPorts = PortScanner.listening() }

        var runaway: [ProcSample] = []
        let window = mode.runawayMinutes * 60
        for p in procs where p.avgCPU >= mode.runawayCPU && p.pid != getpid() {
            if let a = sampler.history.average(p.key, over: window, now: now), a.span >= window - 20, a.cpu * 100 >= mode.runawayCPU {
                runaway.append(p)
            }
        }

        let out = SampleOutput(processes: procs, battery: PowerReader.battery(),
                               thermalState: ProcessInfo.processInfo.thermalState, thermal: thermal,
                               assertions: PowerReader.assertions(), ports: mode.ports ? lastPorts : nil,
                               wattsPerCore: sampler.wattsPerCore, runaway: runaway,
                               cpuLoad: stats.cpuLoad(), memory: stats.memory(), disk: lastDisk.d,
                               health: lastHealth.h)
        DispatchQueue.main.async { [weak self] in self?.onSample?(out) }
    }
}
