import Foundation
import AppKit
import CryptoKit

// MARK: - Auth service
// Uses Supabase REST + Auth APIs directly via URLSession — no external SDK required.
// Opens the Google OAuth flow in the user's default browser via NSWorkspace.
// The callback (quickpanel://auth/callback?code=...) is delivered through
// `handleOAuthCallback(url:)` — wired up in the AppDelegate via
// `application(_:open:)` and the NSAppleEventManager handler.
//
// ⚠️ Manual step — Supabase dashboard:
// In Supabase → Authentication → URL Configuration → Redirect URLs, ensure
// "quickpanel://auth/callback" is listed. This cannot be changed from code.
@MainActor
final class AuthService: ObservableObject {

    static let shared = AuthService()

    @Published var isSignedIn:    Bool     = false
    @Published var isLoading:     Bool     = false
    @Published var currentUser:   AppUser? = nil
    @Published var errorMessage:  String?  = nil

    // MARK: - Persisted tokens

    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "sb.accessToken") }
        set { UserDefaults.standard.set(newValue, forKey: "sb.accessToken") }
    }
    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: "sb.refreshToken") }
        set { UserDefaults.standard.set(newValue, forKey: "sb.refreshToken") }
    }

    private static let pkceVerifierKey = "pkce_code_verifier"

    /// Guards against macOS delivering the same callback URL twice
    /// (once via `application(_:open:)` and once via the Apple Event handler).
    private var isExchangingCode = false

    private init() {}

    // MARK: - Check session on launch

    func checkSession() async {
        guard let token = accessToken else { return }
        do {
            let su      = try await fetchSupabaseUser(accessToken: token)
            let appUser = try await createOrFetchUser(supabaseID: su.id, googleId: su.id,
                                                      email: su.email, name: su.fullName,
                                                      avatarURL: su.avatarURL, accessToken: token)
            self.currentUser = appUser
            self.isSignedIn  = true
        } catch {
            clearTokens()
        }
    }

    // MARK: - Sign in with Google (NSWorkspace — opens in user's default browser)

    func signInWithGoogle() async {
        isLoading    = true
        errorMessage = nil

        guard let oauthURL = buildGoogleOAuthURL() else {
            isLoading    = false
            errorMessage = "Bad URL"
            return
        }

        PanelController.shared?.hidePanel()
        // Open in existing browser — no new window
        NSWorkspace.shared.open(oauthURL)
    }

    private func buildGoogleOAuthURL() -> URL? {
        let verifier  = pkceVerifier()
        let challenge = pkceChallenge(for: verifier)

        // Persist verifier so it is available when the callback arrives in a
        // separate app activation.
        UserDefaults.standard.set(verifier, forKey: Self.pkceVerifierKey)

        guard var components = URLComponents(string:
                "\(SupabaseConfig.projectURL)/auth/v1/authorize") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "provider",              value: "google"),
            URLQueryItem(name: "redirect_to",           value: "https://vedantvaibhav.github.io/stash-releases/auth/success"),
            URLQueryItem(name: "flow_type",             value: "pkce"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(
                name: "scopes",
                value: "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
            ),
        ]
        return components.url
    }

    // MARK: - Handle OAuth callback (called from AppDelegate URL handlers)

    func handleOAuthCallback(url: URL) async {
        // macOS occasionally delivers the callback twice (application(_:open:)
        // AND the Apple Event handler). Without this guard, the second exchange
        // reuses the consumed code and overwrites the successful state.
        if isSignedIn || isExchangingCode { return }

        // Merge query params and URL fragment — Supabase sometimes returns tokens in the hash.
        var params: [String: String] = [:]
        if let query = url.query       { params.merge(parseQuery(query))    { _, new in new } }
        if let fragment = url.fragment { params.merge(parseQuery(fragment)) { _, new in new } }

        if let err = params["error"] {
            let desc = params["error_description"]?.replacingOccurrences(of: "+", with: " ") ?? err
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Google sign in failed: \(desc)"
            }
            return
        }

        guard let code = params["code"] else {
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "No authorization code received"
            }
            return
        }

        await MainActor.run {
            self.isLoading    = true
            self.errorMessage = nil
        }
        isExchangingCode = true
        await exchangeCodeForSession(code)
        isExchangingCode = false
    }

    // MARK: - Sign out

    func signOut() async {
        clearTokens()
        currentUser = nil
        isSignedIn  = false
    }

    // MARK: - Helpers

    var trialDaysRemaining: Int {
        guard let user = currentUser else { return 30 }
        return max(0, Calendar.current.dateComponents([.day], from: Date(),
                                                      to: user.trialEndDate).day ?? 0)
    }

    // MARK: - Private: complete sign-in with an access token

    private func finishWithToken(_ token: String, refresh: String?) async {
        accessToken  = token
        refreshToken = refresh
        do {
            let su      = try await fetchSupabaseUser(accessToken: token)
            let appUser = try await createOrFetchUser(supabaseID: su.id, googleId: su.id,
                                                      email: su.email, name: su.fullName,
                                                      avatarURL: su.avatarURL, accessToken: token)
            // Explicit main-actor hop so @Published updates always trigger SwiftUI redraw
            // — even if this runs from a non-isolated await resumption point.
            await MainActor.run {
                self.currentUser = appUser
                self.isSignedIn  = true
                self.isLoading   = false
                PanelController.shared?.showPanel()
            }
            NotificationCenter.default.post(name: .authCompleted, object: nil)
        } catch {
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Sign in failed: \(error.localizedDescription)"
            }
            clearTokens()
        }
    }

    // MARK: - Private: PKCE code exchange

    private func exchangeCodeForSession(_ code: String) async {
        guard let url = URL(string:
            "\(SupabaseConfig.projectURL)/auth/v1/token?grant_type=pkce") else {
            await MainActor.run { self.isLoading = false }
            return
        }

        let verifier = retrieveCodeVerifier()

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json",     forHTTPHeaderField: "Content-Type")
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.httpBody = try JSONSerialization.data(withJSONObject:
                ["auth_code": code, "code_verifier": verifier])

            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json  = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                await MainActor.run {
                    self.isLoading    = false
                    self.errorMessage = "Authentication failed — please try again."
                }
                return
            }

            // Clean up the verifier only after a successful exchange.
            UserDefaults.standard.removeObject(forKey: Self.pkceVerifierKey)

            await finishWithToken(token, refresh: json["refresh_token"] as? String)
        } catch {
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Authentication failed — please try again."
            }
        }
    }

    // MARK: - Private: PKCE helpers

    private func pkceVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func pkceChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func retrieveCodeVerifier() -> String {
        UserDefaults.standard.string(forKey: Self.pkceVerifierKey) ?? ""
    }

    // MARK: - Private: fetch auth/v1/user

    private func fetchSupabaseUser(accessToken: String) async throws -> SupabaseUserResponse {
        guard let url = URL(string: "\(SupabaseConfig.projectURL)/auth/v1/user") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(SupabaseConfig.anonKey,  forHTTPHeaderField: "apikey")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw NSError(domain: "Auth", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        return try JSONDecoder().decode(SupabaseUserResponse.self, from: data)
    }

    // MARK: - Private: upsert user in rest/v1/users

    private func createOrFetchUser(supabaseID: String, googleId: String,
                                   email: String, name: String,
                                   avatarURL: String, accessToken: String) async throws -> AppUser {
        // Attempt to fetch existing row
        guard let getURL = URL(string:
            "\(SupabaseConfig.projectURL)/rest/v1/users?google_id=eq.\(googleId)&limit=1")
        else { throw URLError(.badURL) }

        var getReq = URLRequest(url: getURL)
        getReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        getReq.setValue(SupabaseConfig.anonKey,  forHTTPHeaderField: "apikey")
        getReq.setValue("application/json",      forHTTPHeaderField: "Accept")

        let (getData, _) = try await URLSession.shared.data(for: getReq)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(flexibleISO8601)
        if let existing = try? decoder.decode([AppUser].self, from: getData),
           let user = existing.first {
            try? await patchLastSeen(googleId: googleId, accessToken: accessToken)
            return user
        }

        // Create new row
        let trialEnd = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
        let newUser  = AppUser(
            id: supabaseID, googleId: googleId, email: email, name: name,
            avatarUrl: avatarURL, trialStartDate: Date(), trialEndDate: trialEnd,
            status: "trial", plan: "free", createdAt: Date(), lastSeen: Date()
        )

        guard let postURL = URL(string: "\(SupabaseConfig.projectURL)/rest/v1/users") else {
            throw URLError(.badURL)
        }
        var postReq = URLRequest(url: postURL)
        postReq.httpMethod = "POST"
        postReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        postReq.setValue(SupabaseConfig.anonKey,  forHTTPHeaderField: "apikey")
        postReq.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        postReq.setValue("return=minimal",        forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        postReq.httpBody = try encoder.encode(newUser)

        _ = try await URLSession.shared.data(for: postReq)
        return newUser
    }

    private func patchLastSeen(googleId: String, accessToken: String) async throws {
        guard let url = URL(string:
            "\(SupabaseConfig.projectURL)/rest/v1/users?google_id=eq.\(googleId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(SupabaseConfig.anonKey,  forHTTPHeaderField: "apikey")
        req.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        let body = ["last_seen": ISO8601DateFormatter().string(from: Date())]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Private: helpers

    private func clearTokens() {
        UserDefaults.standard.removeObject(forKey: "sb.accessToken")
        UserDefaults.standard.removeObject(forKey: "sb.refreshToken")
    }

    private func parseQuery(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in string.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }

    private func flexibleISO8601(_ decoder: Decoder) throws -> Date {
        let c   = try decoder.singleValueContainer()
        let str = try c.decode(String.self)
        let f1  = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2  = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: str) { return d }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(str)")
    }
}

// MARK: - Private: Supabase auth/v1/user response model

private struct SupabaseUserResponse: Decodable {
    let id:        String
    let email:     String
    let fullName:  String
    let avatarURL: String

    private enum CodingKeys: String, CodingKey {
        case id, email
        case userMetadata = "user_metadata"
    }

    private struct Meta: Decodable {
        let full_name:  String?
        let name:       String?
        let avatar_url: String?
        let picture:    String?
    }

    init(from decoder: Decoder) throws {
        let c     = try decoder.container(keyedBy: CodingKeys.self)
        id        = (try? c.decode(String.self, forKey: .id))    ?? ""
        email     = (try? c.decode(String.self, forKey: .email)) ?? ""
        var fn    = ""
        var av    = ""
        if let meta = try? c.decode(Meta.self, forKey: .userMetadata) {
            fn = meta.full_name ?? meta.name ?? ""
            av = meta.avatar_url ?? meta.picture ?? ""
        }
        fullName  = fn
        avatarURL = av
    }
}
