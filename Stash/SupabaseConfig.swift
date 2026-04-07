import Foundation

// MARK: - Supabase project constants

/// Values come from `APIKeys` (environment or `Secrets.plist` — see `Secrets.example.plist`).
enum SupabaseConfig {
    static var projectURL: String { APIKeys.supabaseProjectURL }
    static var anonKey: String { APIKeys.supabaseAnonKey }
}
