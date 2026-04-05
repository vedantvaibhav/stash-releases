import Foundation

// MARK: - App user model (mirrors the `users` table in Supabase)
struct AppUser: Codable, Identifiable {
    let id:             String
    let googleId:       String
    let email:          String
    let name:           String
    let avatarUrl:      String
    let trialStartDate: Date
    let trialEndDate:   Date
    var status:         String
    var plan:           String
    let createdAt:      Date
    var lastSeen:       Date

    enum CodingKeys: String, CodingKey {
        case id
        case googleId       = "google_id"
        case email, name
        case avatarUrl      = "avatar_url"
        case trialStartDate = "trial_start_date"
        case trialEndDate   = "trial_end_date"
        case status, plan
        case createdAt      = "created_at"
        case lastSeen       = "last_seen"
    }
}
