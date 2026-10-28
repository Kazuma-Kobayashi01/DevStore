import Foundation

// Create an empty environment, delete an environment, and list plans awaiting the user.
extension Operations {
    public static let minimumCreateFreeBytes: Int64 = 1 << 30

    // MARK: create

    public func planCreate(storeQuery: String, kind: String, slot: String, name: String, sizeGiB: Int) throws -> Plan {
        guard Adapters.validName(kind) else { throw DevStoreError("invalid kind \(kind): use lowercase letters, digits, '-' and '.'") }
        guard Adapters.validName(slot) else { throw DevStoreError("invalid slot \(slot): use lowercase letters, digits, '-' and '.'") }
        guard (1...2048).contains(sizeGiB) else { throw DevStoreError("size must be 1–2048 GiB") }
        let store = try library.resolveStore(storeQuery)
        let envId = newId(), imageId = newId()
        let dest = library.environmentDir(store: store, kind: kind, environmentId: envId)
            .appendingPathComponent("images/\(imageId)/environment.sparsebundle").path
        let slotPath = library.paths.slotPath(kind: kind, slot: slot)
        let targets = ["storeId": store.storeId, "kind": kind, "slot": slot, "displayName": name,
                       "environmentId": envId, "imageId": imageId, "destination": dest, "slotPath": slotPath,
                       "sizeGiB": String(sizeGiB), "adapter": EmptyAdapter().ref.id]
        let checks = try createChecks(targets)
        try requireAll(checks)
        return try finish(Plan(
            planId: newId(), action: .create, level: PlanAction.create.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: [
                "create an empty APFS sparse bundle at \(dest) (grows on demand, at most \(sizeGiB) GiB)",
                "create slot placeholder \(slotPath) if missing",
                "attach it at \(slotPath); create \(EmptyAdapter.layout.joined(separator: ", ")); write .devstore/manifest.json",
                "detach; write environment.json and image.json; bind slot \(kind)/\(slot) in the host registry",
            ],
            notTouched: ["existing environments and images", "global shell configuration"], createdAt: timestamp()))
    }

    func createChecks(_ t: [String: String]) throws -> [Precondition] {
        let reg = try library.loadRegistry()
        let slotPath = t["slotPath"]!
        let store = reg.stores.first { $0.storeId == t["storeId"] }
        let free = (try? URL(fileURLWithPath: store?.path ?? "/").resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? 0
        return [
            Precondition(description: "store \(t["storeId"]!) is registered and online", ok: store.map(library.isOnline) ?? false),
            Precondition(description: "slot \(t["kind"]!)/\(t["slot"]!) is not bound to another environment",
                         ok: !reg.slots.contains { $0.kind == t["kind"] && $0.slot == t["slot"] }),
            Precondition(description: "slot placeholder \(slotPath) is absent or an empty, unmounted directory",
                         ok: placeholderUsable(slotPath)),
            Precondition(description: "destination does not exist yet", ok: !fm.fileExists(atPath: t["destination"]!)),
            Precondition(description: "store volume has ≥ 1 GiB free", ok: free >= Self.minimumCreateFreeBytes),
        ]
    }

    func placeholderUsable(_ slotPath: String) -> Bool {
        !fm.fileExists(atPath: slotPath)
            || (!DiskImage.isMountPoint(slotPath) && ((try? fm.contentsOfDirectory(atPath: slotPath)) ?? ["?"]).isEmpty)
    }

    func executeCreate(_ plan: Plan, _ journal: Journal) throws -> String {
        let t = plan.targets
        let adapter = EmptyAdapter()
        let dest = t["destination"]!, slotPath = t["slotPath"]!
        let imageDir = URL(fileURLWithPath: dest).deletingLastPathComponent()
        let envDir = imageDir.deletingLastPathComponent().deletingLastPathComponent()
        var created = false, attached = false
        do {
            try fm.createDirectory(at: imageDir, withIntermediateDirectories: true)
            created = true
            try DiskImage.create(bundle: dest, sizeGiB: Int(t["sizeGiB"]!)!, volumeName: "DevStore-\(t["kind"]!)-\(t["slot"]!)")
            journal.log("step", step: "create", detail: dest)
            try fm.createDirectory(atPath: slotPath, withIntermediateDirectories: true)
            try DiskImage.attach(bundle: dest, mountPoint: slotPath)
            attached = true
            journal.log("step", step: "attach", detail: slotPath)
            let info = try DiskImage.volumeInfo(mountPoint: slotPath)
            try adapter.prepareLayout(mount: slotPath)
            let manifest = VolumeManifest(environmentId: t["environmentId"]!, imageId: t["imageId"]!, kind: t["kind"]!,
                                          slot: t["slot"]!, adapter: adapter.ref, fixedMountPath: slotPath, writtenAt: timestamp())
            try JSONIO.writeAtomically(manifest, to: URL(fileURLWithPath: slotPath).appendingPathComponent(".devstore/manifest.json"))
            journal.log("step", step: "layout+manifest")
            try DiskImage.detach(mountPoint: slotPath)
            attached = false
            journal.log("step", step: "detach")
            let now = timestamp()
            let image = ImageRecord(
                imageId: t["imageId"]!, environmentId: t["environmentId"]!, storeId: t["storeId"]!,
                relativePath: "environments/\(t["kind"]!)/\(t["environmentId"]!)/images/\(t["imageId"]!)/environment.sparsebundle",
                volumeUUID: info.volumeUUID, role: .active, lineage: Lineage(reason: "created empty (\(t["sizeGiB"]!) GiB)"),
                fixedMountPath: slotPath, hostBinding: .current(), createdAt: now)
            try JSONIO.writeAtomically(image, to: imageDir.appendingPathComponent("image.json"))
            let env = EnvironmentRecord(
                environmentId: t["environmentId"]!, kind: t["kind"]!, slot: t["slot"]!, displayName: t["displayName"]!,
                adapter: adapter.ref, activeImageId: t["imageId"]!, origin: Origin(type: "created", note: "empty"), createdAt: now)
            try JSONIO.writeAtomically(env, to: envDir.appendingPathComponent("environment.json"))
            var reg = try library.loadRegistry()
            reg.slots.append(SlotBinding(kind: t["kind"]!, slot: t["slot"]!, environmentId: t["environmentId"]!, storeId: t["storeId"]!))
            try library.saveRegistry(reg)
            journal.log("step", step: "register")
            return "created empty environment \(t["kind"]!)/\(t["slot"]!) (\(t["environmentId"]!), volume \(info.volumeUUID))"
        } catch {
            if attached { try? DiskImage.detach(mountPoint: slotPath) }
            if created { try? fm.removeItem(at: envDir) }
            journal.log("rolledBack", detail: "detached=\(attached) removedNewImage=\(created)")
            throw error
        }
    }

    // MARK: delete

    public func planDelete(_ query: String) throws -> Plan {
        let r = try library.resolve(query)
        let targets = ["environmentId": r.environment.environmentId, "kind": r.environment.kind, "slot": r.environment.slot,
                       "storeId": r.store.storeId, "environmentDir": r.environmentDir.path, "slotPath": r.slotPath,
                       "displayName": r.environment.displayName]
        let checks = try deleteChecks(targets)
        try requireAll(checks)
        let images = (try? fm.contentsOfDirectory(atPath: r.environmentDir.path + "/images")) ?? []
        return try finish(Plan(
            planId: newId(), action: .delete, level: PlanAction.delete.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: [
                "move \(r.environmentDir.path) to the Trash — \(images.count) image(s), records and verification results",
                "unbind slot \(r.environment.kind)/\(r.environment.slot) from the host registry",
                "remove the empty slot placeholder \(r.slotPath)",
            ],
            notTouched: ["other environments", "original installations", "files outside the environment directory"],
            createdAt: timestamp()))
    }

    func deleteChecks(_ t: [String: String]) throws -> [Precondition] {
        let reg = try library.loadRegistry()
        let envDir = t["environmentDir"]!, slotPath = t["slotPath"]!
        let store = reg.stores.first { $0.storeId == t["storeId"] }
        let images = (try? fm.contentsOfDirectory(atPath: envDir + "/images")) ?? []
        let leased = images.filter { fm.fileExists(atPath: "\(envDir)/images/\($0)/lease.json") }
        return [
            Precondition(description: "store \(t["storeId"]!) is online", ok: store.map(library.isOnline) ?? false),
            Precondition(description: "environment directory exists", ok: fm.fileExists(atPath: envDir + "/environment.json")),
            Precondition(description: "slot \(slotPath) is not mounted", ok: !DiskImage.isMountPoint(slotPath)),
            Precondition(description: "no image of the environment holds a lease", ok: leased.isEmpty),
        ]
    }

    func executeDelete(_ plan: Plan, _ journal: Journal) throws -> String {
        let t = plan.targets
        let trashed = try trash(URL(fileURLWithPath: t["environmentDir"]!))
        journal.log("step", step: "trash", detail: trashed.path)
        var reg = try library.loadRegistry()
        reg.slots.removeAll { $0.environmentId == t["environmentId"] }
        try library.saveRegistry(reg)
        journal.log("step", step: "unbind")
        let slotPath = t["slotPath"]!
        if placeholderUsable(slotPath), fm.fileExists(atPath: slotPath) { try? fm.removeItem(atPath: slotPath) }
        return "deleted \(t["kind"]!)/\(t["slot"]!); moved to \(trashed.path)"
    }

    @Sendable public static func moveToTrash(_ url: URL) throws -> URL {
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return (out as URL?) ?? url
    }

    // MARK: pending plans

    public struct PlanEntry: Sendable {
        public var plan: Plan
        public var state: Authorizer.PlanState
    }

    /// Saved plans that have not run or been rejected, newest first.
    public func pendingPlans() throws -> [PlanEntry] {
        let auth = Authorizer(paths: library.paths)
        let dir = library.paths.plansDir
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name -> PlanEntry? in
            guard let plan = try? JSONIO.read(Plan.self, from: dir.appendingPathComponent(name)),
                  (try? plan.computedDigest()) == plan.planDigest,
                  let state = try? auth.state(of: plan), state != .done else { return nil }
            return PlanEntry(plan: plan, state: state)
        }.sorted { $0.plan.createdAt > $1.plan.createdAt }
    }
}
