import Foundation
import AppKit
import AuthenticationServices
import CryptoKit

// MARK: - Auth service
// Uses Supabase REST + Auth APIs directly via URLSession — no external SDK required.
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

    private init() {}

    // MARK: - Check session on launch

    func checkSession() async {
        guard let token = accessToken else {
            print("[Auth] No stored access token")
            return
        }
        do {
            let su      = try await fetchSupabaseUser(accessToken: token)
            let appUser = try await createOrFetchUser(supabaseID: su.id, googleId: su.id,
                                                      email: su.email, name: su.fullName,
                                                      avatarURL: su.avatarURL, accessToken: token)
            self.currentUser = appUser
            self.isSignedIn  = true
            print("[Auth] Session restored: \(appUser.email)")
        } catch {
            print("[Auth] Stored session invalid, clearing: \(error)")
            clearTokens()
        }
    }

    // MARK: - Sign in with Google (ASWebAuthenticationSession + PKCE)

    func signInWithGoogle() async {
        print("[Auth] ====== signInWithGoogle() called ======")
        isLoading    = true
        errorMessage = nil

        // Build OAuth URL with explicit PKCE parameters so Supabase returns ?code=
        // and can exchange it reliably for a session.
        let verifier = pkceVerifier()
        let challenge = pkceChallenge(for: verifier)

        guard var components = URLComponents(string:
                "\(SupabaseConfig.projectURL)/auth/v1/authorize") else {
            print("[Auth] ERROR: Could not create URL components")
            isLoading    = false
            errorMessage = "Bad URL"
            return
        }
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: "quickpanel://auth/callback"),
            URLQueryItem(name: "flow_type", value: "pkce"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(
                name: "scopes",
                value: "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
            ),
        ]
        guard let oauthURL = components.url else {
            print("[Auth] ERROR: Could not build OAuth URL")
            isLoading    = false
            errorMessage = "Bad URL"
            return
        }
        print("[Auth] OAuth URL: \(oauthURL.absoluteString)")

        // Log available windows
        print("[Auth] Visible windows: \(NSApp.windows.filter { $0.isVisible }.count)")
        print("[Auth] All windows: \(NSApp.windows.count)")
        for (i, w) in NSApp.windows.enumerated() {
            print("[Auth] Window \(i): \(type(of: w)) visible=\(w.isVisible) key=\(w.isKeyWindow)")
        }

        print("[Auth] Creating ASWebAuthenticationSession")
        let session = ASWebAuthenticationSession(
            url: oauthURL,
            callbackURLScheme: "quickpanel"
        ) { [weak self] callbackURL, error in
            print("[Auth] ====== ASWebAuthenticationSession callback fired ======")

            if let error = error {
                print("[Auth] Session error type: \(type(of: error))")
                print("[Auth] Session error: \(error)")
                print("[Auth] Session error localised: \(error.localizedDescription)")
                if let authError = error as? ASWebAuthenticationSessionError {
                    print("[Auth] ASWebAuthenticationSessionError code: \(authError.code.rawValue)")
                }
                let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                Task { @MainActor in
                    self?.isLoading = false
                    if !cancelled { self?.errorMessage = "Sign in error: \(error.localizedDescription)" }
                }
                return
            }

            guard let url = callbackURL else {
                print("[Auth] ERROR: callbackURL is nil with no error")
                Task { @MainActor in
                    self?.isLoading  = false
                    self?.errorMessage = "No callback URL received"
                }
                return
            }

            print("[Auth] SUCCESS — callback URL: \(url.absoluteString)")
            print("[Auth] Query:    \(url.query    ?? "NIL")")
            print("[Auth] Fragment: \(url.fragment ?? "NIL")")

            Task {
                await self?.finishWithCallbackURL(url, codeVerifier: verifier)
            }
        }

        print("[Auth] Setting presentation context provider")
        session.presentationContextProvider = AuthPresentationContext.shared
        session.prefersEphemeralWebBrowserSession = false

        print("[Auth] Calling session.start()")
        let started = session.start()
        print("[Auth] session.start() returned: \(started)")

        // Store strongly so it isn't released before the callback fires
        AuthPresentationContext.shared.activeSession = session

        if !started {
            print("[Auth] ERROR: session.start() returned false")
            isLoading    = false
            errorMessage = "Could not start sign in"
        }
    }

    // MARK: - Handle external URL callback (Apple Event fallback path)

    func handleAuthCallback(url: URL) async {
        print("[Auth] External callback: \(url.absoluteString)")
        isLoading    = true
        errorMessage = nil
        await finishWithCallbackURL(url, codeVerifier: nil)
    }

    // MARK: - Private: extract code/token from callback and finish sign-in

    private func finishWithCallbackURL(_ url: URL, codeVerifier: String?) async {
        let raw = url.absoluteString
        print("[Auth] Processing callback: \(raw)")
        print("[Auth] query=\(url.query ?? "nil")  fragment=\(url.fragment ?? "nil")")

        // 0. Provider/Supabase returned an explicit OAuth error.
        // Example from logs:
        // quickpanel://auth/callback?error=server_error&error_description=Unable+to+exchange+external+code...
        if let query = url.query {
            let q = parseQuery(query)
            if let err = q["error"] {
                let desc = q["error_description"]?.replacingOccurrences(of: "+", with: " ") ?? err
                print("[Auth] OAuth error from callback query: \(err) — \(desc)")
                isLoading = false
                errorMessage = "Google sign in failed: \(desc)"
                return
            }
        }
        if let fragment = url.fragment {
            let f = parseQuery(fragment)
            if let err = f["error"] {
                let desc = f["error_description"]?.replacingOccurrences(of: "+", with: " ") ?? err
                print("[Auth] OAuth error from callback fragment: \(err) — \(desc)")
                isLoading = false
                errorMessage = "Google sign in failed: \(desc)"
                return
            }
        }

        // 1. PKCE code in query params (?code=...) — preferred, always preserved
        if let query = url.query {
            let params = parseQuery(query)
            if let code = params["code"] {
                print("[Auth] Got PKCE code — exchanging for tokens")
                await exchangeCodeForSession(code: code, verifier: codeVerifier ?? "")
                return
            }
        }

        // 2. Implicit flow — access_token in fragment or query
        var tokenString: String? = nil
        if let frag = url.fragment, !frag.isEmpty {
            tokenString = frag
            print("[Auth] Token source: URL.fragment")
        } else if let query = url.query, query.contains("access_token") {
            tokenString = query
            print("[Auth] Token source: query string")
        } else if raw.contains("#") {
            tokenString = raw.components(separatedBy: "#").last
            print("[Auth] Token source: raw '#' split")
        }

        if let tokenString = tokenString {
            var params: [String: String] = [:]
            for pair in tokenString.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                guard kv.count == 2 else { continue }
                params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
            }
            print("[Auth] Params found: \(params.keys.sorted().joined(separator: ", "))")
            if let token = params["access_token"] {
                print("[Auth] Got implicit access_token")
                await finishWithToken(token, refresh: params["refresh_token"])
                return
            }
        }

        isLoading    = false
        errorMessage = "No token received — please try again."
        print("[Auth] No code or token found in: \(raw)")
    }

    // MARK: - Sign out

    func signOut() async {
        clearTokens()
        currentUser = nil
        isSignedIn  = false
        print("[Auth] Signed out")
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
            self.currentUser = appUser
            self.isSignedIn  = true
            self.isLoading   = false
            NotificationCenter.default.post(name: .authCompleted, object: nil)
            print("[Auth] Sign in complete: \(appUser.email)")
        } catch {
            isLoading    = false
            errorMessage = "Sign in failed: \(error.localizedDescription)"
            clearTokens()
            print("[Auth] finishWithToken error: \(error)")
        }
    }

    // MARK: - Private: PKCE code exchange

    private func exchangeCodeForSession(code: String, verifier: String) async {
        guard let url = URL(string:
            "\(SupabaseConfig.projectURL)/auth/v1/token?grant_type=pkce") else {
            isLoading = false; return
        }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json",     forHTTPHeaderField: "Content-Type")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.httpBody = try JSONSerialization.data(withJSONObject:
                ["auth_code": code, "code_verifier": verifier])

            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            print("[Auth] Token exchange HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")

            guard let json  = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                throw URLError(.badServerResponse)
            }
            await finishWithToken(token, refresh: json["refresh_token"] as? String)
        } catch {
            isLoading    = false
            errorMessage = "Authentication failed — please try again."
            print("[Auth] Code exchange error: \(error)")
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
            print("[Auth] Existing user: \(user.email)")
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

        let (_, postResponse) = try await URLSession.shared.data(for: postReq)
        let postStatus = (postResponse as? HTTPURLResponse)?.statusCode ?? 0
        print("[Auth] Created user row, HTTP \(postStatus)")
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

// MARK: - Notification name

extension NSNotification.Name {
    static let authCompleted = NSNotification.Name("AuthCompleted")
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
