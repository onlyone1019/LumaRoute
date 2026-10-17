import Foundation
import LumaRouteCore

@main enum UpdateChoiceCheck {
    @MainActor static func main() async throws {
        let root = LocalStore.applicationRoot()
        let local = try LocalStore(root:root)
        var database = AppDatabase()
        let profile = Profile(name:"update-node-selection",isRemote:false)
        database.profiles = [profile]; database.activeProfileID = profile.id
        database.settings.controllerPort = Int(CommandLine.arguments[1])!
        database.settings.mixedPort = Int(CommandLine.arguments[2])!
        database.settings.connectOnLaunch = false
        database.savedChoices = ["update-fixture":"REJECT"]
        let yaml = "proxies: []\nproxy-groups: [{name: update-fixture, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,DIRECT']\ndns: {enable: false}"
        try local.commit(database,profiles:[profile.id:yaml])
        try local.secrets.write("update-fixture-secret",key:"controller-secret")
        try AppUpdateHandoff(targetBuild:1002,settings:database.settings).save(in:root)
        let app = AppStore()
        await app.bootstrap()
        guard app.coreReady else { await app.shutdown(); throw LumaError.message(app.error ?? "isolated core did not start") }
        do {
            let groups = try await app.api.proxies()
            guard groups["update-fixture"]?.now == "REJECT" else { throw LumaError.message("saved choice was not restored in the running core") }
            guard try local.load().savedChoices == database.savedChoices,
                  try local.load().settings == database.settings,
                  try local.profileContent(profile.id) == yaml,
                  try AppUpdateHandoff.take(in:root,currentBuild:1002) == nil else { throw LumaError.message("configuration changed during restart") }
            await app.shutdown()
            print("PASS production bootstrap restores saved node in real isolated Mihomo; SQLite, profile and launch preference preserved")
        } catch { await app.shutdown(); throw error }
    }
}
