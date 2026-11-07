import Foundation

public struct Precondition: Sendable {
    public var description: String
    public var ok: Bool
}

/// Builds plans, re-checks their preconditions, and executes them as journaled transactions.
/// Authorization is checked by the caller (see `Authorizer`) before `execute`.
public struct Operations: Sendable {
    public var library: Library
    /// Where deleted environments go; tests substitute a temporary directory.
    public var trash: @Sendable (URL) throws -> URL

    public init(library: Library = Library(), trash: @escaping @Sendable (URL) throws -> URL = Operations.moveToTrash) {
        self.library = library
        self.trash = trash
    }

    var fm: FileManager { .default }

    // MARK: plan storage

    public func save(_ plan: Plan) throws {
        try JSONIO.writeAtomically(plan, to: library.paths.plansDir.appendingPathComponent("\(plan.planId).json"))
    }

    public func loadPlan(_ planId: String) throws -> Plan {
        let dir = library.paths.plansDir
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let matches = names.filter { $0.hasPrefix(planId.lowercased()) && $0.hasSuffix(".json") }
        guard matches.count == 1 else { throw DevStoreError("no unique plan matches \(planId)") }
        let plan = try JSONIO.read(Plan.self, from: dir.appendingPathComponent(matches[0]))
        guard try plan.computedDigest() == plan.planDigest else {
            throw DevStoreError("plan \(plan.planId) was modified after it was created (digest mismatch)")
        }
        return plan
    }

    func finish(_ plan: Plan) throws -> Plan {
        var p = plan
        p.planDigest = try p.computedDigest()
        try save(p)
        return p
    }

    func requireAll(_ checks: [Precondition]) throws {
        let failed = checks.filter { !$0.ok }
        if !failed.isEmpty {
            throw DevStoreError("preconditions not met:\n" + failed.map { "  ✗ \($0.description)" }.joined(separator: "\n"))
        }
    }

    // MARK: import

    public func planImport(source: String, storeQuery: String, kind: String, slot: String, name: String) throws -> Plan {
        guard Adapters.forImport(kind: kind) != nil else { throw DevStoreError("importing kind \(kind) is not supported (only miniconda)") }
        guard Adapters.validName(slot) else {
            throw DevStoreError("invalid slot name \(slot): use lowercase letters, digits, '-' and '.'")
        }
        let store = try library.resolveStore(storeQuery)
        let src = URL(fileURLWithPath: source).standardizedFileURL.path
        let envId = newId(), imageId = newId()
        let dest = library.environmentDir(store: store, kind: kind, environmentId: envId)
            .appendingPathComponent("images/\(imageId)/environment.sparsebundle").path
        let slotPath = library.paths.slotPath(kind: kind, slot: slot)
        let targets = ["source": src, "storeId": store.storeId, "kind": kind, "slot": slot, "displayName": name,
                       "environmentId": envId, "imageId": imageId, "destination": dest, "slotPath": slotPath]
        let checks = try importChecks(targets)
        try requireAll(checks)
        let plan = Plan(
            planId: newId(), action: .importImage, level: PlanAction.importImage.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: [
                "APFS-clone \(src) to \(dest) (copy-on-write; shares storage with the source)",
                "create slot placeholder \(slotPath) if missing",
                "attach the copy at \(slotPath), verify the content was built for that path",
                "write \(slotPath)/.devstore/manifest.json inside the copy",
                "detach; write environment.json and image.json; bind slot \(kind)/\(slot) in the host registry",
            ],
            notTouched: [src, NSHomeDirectory() + "/miniconda3", NSHomeDirectory() + "/.zshrc", "global shell configuration"],
            createdAt: timestamp())
        return try finish(plan)
    }

    func importChecks(_ t: [String: String]) throws -> [Precondition] {
        let reg = try library.loadRegistry()
        let src = t["source"]!, slotPath = t["slotPath"]!
        let store = reg.stores.first { $0.storeId == t["storeId"] }
        let attached = (try? DiskImage.attachedImages()) ?? []
        let slotRoot = library.paths.slotRoot.path
        let placeholderOK = !fm.fileExists(atPath: slotPath)
            || (!DiskImage.isMountPoint(slotPath) && ((try? fm.contentsOfDirectory(atPath: slotPath)) ?? ["?"]).isEmpty)
        let need = DiskImage.allocatedBytes(src)
        let free = (try? URL(fileURLWithPath: store?.path ?? "/").resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? 0
        return [
            Precondition(description: "source \(src) is a sparse bundle", ok: DiskImage.isSparseBundle(src)),
            Precondition(description: "source is not attached", ok: !attached.contains { $0.imagePath == src }),
            Precondition(description: "no disk image is mounted under \(slotRoot)",
                         ok: !attached.contains { $0.mountPoints.contains { $0.hasPrefix(slotRoot + "/") } }),
            Precondition(description: "store \(t["storeId"]!) is registered and online", ok: store.map(library.isOnline) ?? false),
            Precondition(description: "slot \(t["kind"]!)/\(t["slot"]!) is not bound to another environment",
                         ok: !reg.slots.contains { $0.kind == t["kind"] && $0.slot == t["slot"] }),
            Precondition(description: "slot placeholder \(slotPath) is absent or an empty, unmounted directory", ok: placeholderOK),
            Precondition(description: "store volume has ≥ \(need) bytes free (worst case, no clone sharing)", ok: free >= need),
        ]
    }

    // MARK: mount / unmount

    public func planMount(_ query: String) throws -> Plan {
        let r = try library.resolve(query)
        guard let image = r.image, let bundle = r.bundlePath else { throw DevStoreError("environment has no active image") }
        let targets = ["environmentId": r.environment.environmentId, "imageId": image.imageId,
                       "bundle": bundle, "slotPath": r.slotPath, "volumeUUID": image.volumeUUID ?? ""]
        let checks = try mountChecks(targets)
        try requireAll(checks)
        return try finish(Plan(
            planId: newId(), action: .mount, level: PlanAction.mount.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: reclaimEffects(activeImageLease(r)) + [
                "write lease \(r.leaseURL!.path)", "attach \(bundle) at \(r.slotPath)",
                "verify volume UUID and .devstore/manifest.json; detach again on mismatch"],
            notTouched: ["original installations", "global shell configuration"], createdAt: timestamp()))
    }

    func mountChecks(_ t: [String: String]) throws -> [Precondition] {
        let r = try library.resolve(t["environmentId"]!)
        let slotPath = t["slotPath"]!
        let lease = library.leaseAssessment(r)
        let mountedUUIDs = (try? DiskImage.mountedImageVolumeUUIDs()) ?? [:]
        let entries = (try? fm.contentsOfDirectory(atPath: slotPath)) ?? ["?"]
        return [
            Precondition(description: "store \(r.store.storeId) is online", ok: library.isOnline(r.store)),
            Precondition(description: "image \(t["imageId"]!) is the active image",
                         ok: r.image?.imageId == t["imageId"] && r.image?.role == .active),
            Precondition(description: "bundle exists", ok: DiskImage.isSparseBundle(t["bundle"]!)),
            Precondition(description: "image fixedMountPath equals slot path \(slotPath)", ok: r.image?.fixedMountPath == slotPath),
            Precondition(description: "host binding (user, home, arch) matches",
                         ok: r.image?.hostBinding.compatible(with: .current()) ?? false),
            Precondition(description: "slot placeholder exists, is empty and is not a mount point",
                         ok: !DiskImage.isMountPoint(slotPath) && entries.isEmpty),
            lease.precondition,
            Precondition(description: "no mounted volume has UUID \(t["volumeUUID"]!)",
                         ok: !(t["volumeUUID"] ?? "").isEmpty && mountedUUIDs[t["volumeUUID"]!] == nil),
        ]
    }

    public func planUnmount(_ query: String) throws -> Plan {
        let r = try library.resolve(query)
        guard let image = r.image else { throw DevStoreError("environment has no active image") }
        let targets = ["environmentId": r.environment.environmentId, "imageId": image.imageId, "slotPath": r.slotPath]
        let checks = try unmountChecks(targets)
        try requireAll(checks)
        return try finish(Plan(
            planId: newId(), action: .unmount, level: PlanAction.unmount.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: ["detach \(r.slotPath) (never forced; fails if busy)", "remove lease \(r.leaseURL!.path)"],
            notTouched: ["image content"], createdAt: timestamp()))
    }

    func unmountChecks(_ t: [String: String]) throws -> [Precondition] {
        let r = try library.resolve(t["environmentId"]!)
        return [
            Precondition(description: "\(t["slotPath"]!) is mounted with image \(t["imageId"]!) (identity verified)",
                         ok: r.image?.imageId == t["imageId"] && library.identityVerified(r)),
        ]
    }

    public func recheck(_ plan: Plan) throws -> [Precondition] {
        switch plan.action {
        case .importImage: try importChecks(plan.targets)
        case .create: try createChecks(plan.targets)
        case .installSDK: try installSDKChecks(plan.targets)
        case .copySDK: try copySDKChecks(plan.targets)
        case .mount: try mountChecks(plan.targets)
        case .unmount: try unmountChecks(plan.targets)
        case .compact: try compactChecks(plan.targets)
        case .archive: try archiveChecks(plan.targets)
        case .export: try exportChecks(plan.targets)
        case .delete: try deleteChecks(plan.targets)
        case .clearLease: try clearLeaseChecks(plan.targets)
        }
    }

    // MARK: execute

    /// Re-checks preconditions, then runs the transaction. Caller must have authorized the plan.
    /// `passphrase` is only for encrypted archives; it is entered by the user and never persisted.
    public func execute(_ plan: Plan, passphrase: String? = nil) throws -> String {
        var journal = Journal(url: library.paths.journal, plan: plan)
        journal.transactionId = newId()
        journal.log("started")
        do {
            try requireAll(try recheck(plan))
            let result: String
            switch plan.action {
            case .importImage: result = try executeImport(plan, journal)
            case .create: result = try executeCreate(plan, journal)
            case .installSDK: result = try executeInstallSDK(plan, journal)
            case .copySDK: result = try executeCopySDK(plan, journal)
            case .mount: result = try executeMount(plan, journal)
            case .unmount: result = try executeUnmount(plan, journal)
            case .compact: result = try executeCompact(plan, journal)
            case .archive: result = try executeArchive(plan, journal, passphrase: passphrase)
            case .export: result = try executeExport(plan, journal)
            case .delete: result = try executeDelete(plan, journal)
            case .clearLease: result = try executeClearLease(plan, journal)
            }
            journal.log("committed")
            return result
        } catch {
            journal.log("failed", detail: String(describing: error))
            throw error
        }
    }

    func executeImport(_ plan: Plan, _ journal: Journal) throws -> String {
        let t = plan.targets
        let adapter = Adapters.forImport(kind: t["kind"]!)!
        let dest = t["destination"]!, slotPath = t["slotPath"]!
        let imageDir = URL(fileURLWithPath: dest).deletingLastPathComponent()
        var cloned = false, attached = false
        do {
            try fm.createDirectory(at: imageDir, withIntermediateDirectories: true)
            try DiskImage.cloneBundle(from: t["source"]!, to: dest)
            cloned = true
            journal.log("step", step: "clone", detail: dest)
            try fm.createDirectory(atPath: slotPath, withIntermediateDirectories: true)
            try DiskImage.attach(bundle: dest, mountPoint: slotPath)
            attached = true
            journal.log("step", step: "attach", detail: slotPath)
            let info = try DiskImage.volumeInfo(mountPoint: slotPath)
            let sameUUID = try DiskImage.mountedImageVolumeUUIDs().keys.filter { $0 == info.volumeUUID }
            guard sameUUID.count == 1 else { throw DevStoreError("another mounted volume has UUID \(info.volumeUUID)") }
            guard let built = adapter.builtMountPath(volumeRoot: slotPath) else {
                throw DevStoreError("content not recognized by the \(adapter.ref.id) adapter")
            }
            guard built == slotPath else {
                throw DevStoreError("content was built for \(built), not \(slotPath); moving slots requires relocation (not implemented)")
            }
            guard library.readManifest(mount: slotPath) == nil else {
                throw DevStoreError("volume already has a DevStore manifest; importing managed copies is not supported yet")
            }
            let manifest = VolumeManifest(environmentId: t["environmentId"]!, imageId: t["imageId"]!, kind: t["kind"]!,
                                          slot: t["slot"]!, adapter: adapter.ref, fixedMountPath: slotPath,
                                          writtenAt: timestamp())
            try JSONIO.writeAtomically(manifest, to: URL(fileURLWithPath: slotPath).appendingPathComponent(".devstore/manifest.json"))
            journal.log("step", step: "manifest")
            let components = adapter.discoverComponents(mount: slotPath)
            try DiskImage.detach(mountPoint: slotPath)
            attached = false
            journal.log("step", step: "detach")

            let now = timestamp()
            let image = ImageRecord(
                imageId: t["imageId"]!, environmentId: t["environmentId"]!, storeId: t["storeId"]!,
                relativePath: "environments/\(t["kind"]!)/\(t["environmentId"]!)/images/\(t["imageId"]!)/environment.sparsebundle",
                volumeUUID: info.volumeUUID, role: .active,
                lineage: Lineage(reason: "imported from \(t["source"]!)"),
                fixedMountPath: slotPath, hostBinding: .current(), components: components,
                knownWarnings: adapter.knownWarnings, createdAt: now)
            try JSONIO.writeAtomically(image, to: imageDir.appendingPathComponent("image.json"))
            let env = EnvironmentRecord(
                environmentId: t["environmentId"]!, kind: t["kind"]!, slot: t["slot"]!, displayName: t["displayName"]!,
                adapter: adapter.ref, activeImageId: t["imageId"]!,
                origin: Origin(type: "imported", sourcePath: t["source"]!, note: nil), createdAt: now)
            try JSONIO.writeAtomically(env, to: imageDir.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("environment.json"))
            var reg = try library.loadRegistry()
            reg.slots.append(SlotBinding(kind: t["kind"]!, slot: t["slot"]!, environmentId: t["environmentId"]!,
                                         storeId: t["storeId"]!))
            try library.saveRegistry(reg)
            journal.log("step", step: "register")
            return "imported environment \(t["environmentId"]!) as \(t["kind"]!)/\(t["slot"]!) (image \(t["imageId"]!), volume \(info.volumeUUID))"
        } catch {
            // Safe rollback only: detach and remove the copy this transaction created and never registered.
            if attached { try? DiskImage.detach(mountPoint: slotPath) }
            if cloned { try? fm.removeItem(at: imageDir.deletingLastPathComponent().deletingLastPathComponent()) }
            journal.log("rolledBack", detail: "detached=\(attached) removedCopy=\(cloned)")
            throw error
        }
    }

    func executeMount(_ plan: Plan, _ journal: Journal) throws -> String {
        let r = try library.resolve(plan.targets["environmentId"]!)
        let reg = try library.loadRegistry()
        let leaseURL = r.leaseURL!
        try reclaimStaleLeases(activeImageLease(r), journal)
        try JSONIO.writeAtomically(Lease(hostId: reg.hostId, imageId: r.image!.imageId, mountedAt: timestamp(),
                                         transactionId: journal.transactionId), to: leaseURL)
        journal.log("step", step: "lease")
        do {
            try DiskImage.attach(bundle: r.bundlePath!, mountPoint: r.slotPath)
            journal.log("step", step: "attach")
        } catch {
            try? fm.removeItem(at: leaseURL)
            journal.log("rolledBack", detail: "lease removed")
            throw error
        }
        guard library.identityVerified(r) else {
            try? DiskImage.detach(mountPoint: r.slotPath)
            try? fm.removeItem(at: leaseURL)
            journal.log("rolledBack", detail: "identity mismatch; detached, lease removed")
            throw DevStoreError("mounted volume identity does not match image \(r.image!.imageId); detached again")
        }
        journal.log("step", step: "identity")
        return "mounted \(r.environment.kind)/\(r.environment.slot) at \(r.slotPath)"
    }

    func executeUnmount(_ plan: Plan, _ journal: Journal) throws -> String {
        let r = try library.resolve(plan.targets["environmentId"]!)
        try DiskImage.detach(mountPoint: r.slotPath)
        journal.log("step", step: "detach")
        try? fm.removeItem(at: r.leaseURL!)
        journal.log("step", step: "lease-removed")
        let empty = ((try? fm.contentsOfDirectory(atPath: r.slotPath)) ?? ["?"]).isEmpty
        return "unmounted \(r.slotPath)" + (empty ? "" : " (warning: placeholder is not empty)")
    }
}
