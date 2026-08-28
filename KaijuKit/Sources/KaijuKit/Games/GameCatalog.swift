import Foundation
import AppKit

/// Seeds for "this is probably a game".
///
/// The point of the list isn't to be exhaustive — it can't be. It's to make the
/// Games page useful the first time you open it, so most people never have to add
/// anything by hand. Anything not on it can still be added manually, and nothing
/// is ever auto-recorded without you selecting it.
public enum GameCatalog {
    public static let knownBundleIdentifiers: Set<String> = [
        // Launchers and storefronts
        "com.valvesoftware.steam",
        "com.epicgames.launcher",
        "com.blizzard.worldofwarcraft",
        "net.blizzard.BlizzardApp",
        "com.gog.galaxy",
        "com.heroicgameslauncher.hgl",
        // Games and platforms that run natively on Apple Silicon
        "com.roblox.RobloxPlayer",
        "com.roblox.RobloxStudio",
        "com.mojang.minecraftlauncher",
        "net.minecraft.client",
        "com.riotgames.LeagueofLegends.LeagueClient",
        "com.larian.bg3",
        "com.feralinteractive.shadowofthetombraider",
        "com.aspyr.civilizationvi",
        "com.hoyoverse.genshinimpact",
        "com.innersloth.amongus",
        "com.valvesoftware.dota2",
        "com.square-enix.finalfantasyxiv",
        "com.rockstargames.gtav",
        "com.paradoxinteractive.stellaris",
        "com.klei.donotstarvetogether",
        "com.re-logic.terraria",
        "com.motiontwin.deadcells",
        "com.supergiantgames.hades",
        "com.chucklefish.stardewvalley",
        "com.factorio",
        "com.unity3d.UnityEditor",
        "com.epicgames.UnrealEditor",
        // Windows-compatibility layers people game through on macOS
        "com.isaacmarovitz.Whisky",
        "com.codeweavers.CrossOver",
        "org.openemu.OpenEmu",
        "com.parallels.desktop.console",
        "net.kegworks.KegworksWinery"
    ]

    /// Categories Apple itself marks as games.
    public static func isGameCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        return category.hasPrefix("public.app-category.") && category.contains("games")
    }

    public static func looksLikeGame(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        if let bundleIdentifier, knownBundleIdentifiers.contains(bundleIdentifier) { return true }
        guard let bundleURL, let bundle = Bundle(url: bundleURL) else { return false }
        if isGameCategory(bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String) {
            return true
        }
        // Unity and Unreal ship recognisable payload folders; that's a strong hint
        // for the long tail of indie titles that never set a category.
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        let markers = ["Data/Managed", "UnityPlayer.dylib", "Engine/Binaries"]
        for marker in markers {
            if FileManager.default.fileExists(atPath: resources.appendingPathComponent(marker).path) {
                return true
            }
        }
        return false
    }
}
