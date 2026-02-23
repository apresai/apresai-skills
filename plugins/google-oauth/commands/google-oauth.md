---
name: google-oauth
description: Complete Google OAuth integration guide covering GCP project setup, client ID management, platform-specific configuration (iOS, Flutter, Next.js, Go), ID token verification via JWKS, and long-lived session best practices including token rotation, grace periods, and coordinator patterns. Use when integrating Google Sign-In into any app.
---

# Google OAuth — Complete Integration Guide

## Overview

This skill covers end-to-end Google OAuth integration for apps with:
- **Mobile clients**: iOS (Swift/ASWebAuthenticationSession or Flutter/google_sign_in)
- **Web clients**: Next.js (NextAuth.js v5 / Auth.js)
- **Backend APIs**: Go (Lambda or standalone)
- **Long-lived sessions**: JWT access tokens + rotating refresh tokens

The approach: Google handles identity verification, your backend issues its own JWT tokens for API authentication. Google tokens are only used once at login — your app's session management is fully independent.

---

## Part 1: GCP Project Setup & Client IDs

### 1.1 Create a GCP Project

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or use an existing one)
3. Navigate to **APIs & Services > OAuth consent screen**
4. Choose **External** user type
5. Fill in app name, support email, developer email
6. Add scopes: `email`, `profile`, `openid`
7. Add test users (required while in "Testing" status)
8. Publish the app when ready for production

### 1.2 Create OAuth Client IDs

Navigate to **APIs & Services > Credentials > Create Credentials > OAuth client ID**

You need separate client IDs per platform:

| Platform | Application Type | Notes |
|----------|-----------------|-------|
| Web | Web application | Set authorized redirect URIs for NextAuth callback |
| iOS | iOS | Set bundle ID (e.g., `dev.apresai.ftw`) |
| Android | Android | Set package name + SHA-1 fingerprint |

**Important**: Each platform gets its own Client ID. The backend must accept ALL of them when verifying ID tokens.

### 1.3 Client ID Management

Store client IDs appropriately per layer:

```
# Backend environment / CDK
GOOGLE_CLIENT_ID=816049546145-xxx.apps.googleusercontent.com        # Web
GOOGLE_IOS_CLIENT_ID=816049546145-yyy.apps.googleusercontent.com    # iOS
GOOGLE_ANDROID_CLIENT_ID=816049546145-zzz.apps.googleusercontent.com # Android
```

**Best practice**: Hardcode client IDs in CDK/infrastructure code rather than using env vars. They're not secrets — they're public identifiers. This prevents cross-project env var leakage.

```typescript
// CDK example — hardcoded, not from process.env
const googleClientId = '816049546145-xxx.apps.googleusercontent.com';
const googleIosClientId = '816049546145-yyy.apps.googleusercontent.com';

const sharedEnv: Record<string, string> = {
  GOOGLE_CLIENT_ID: googleClientId,
  GOOGLE_IOS_CLIENT_ID: googleIosClientId,
};
```

### 1.4 File Organization

Keep OAuth credentials documented and version-controlled (minus secrets):

```
~/dev/certs/google-oauth/{project-name}/
├── web_client.json          # Downloaded from GCP console
├── ios_client.plist         # Downloaded from GCP console
└── README.md                # Which client ID is for what
```

---

## Part 2: Platform Configuration

### 2.1 iOS — ASWebAuthenticationSession (PKCE Flow)

Best for apps that need fine-grained control. Uses the system browser for OAuth, no SDK dependency.

```swift
import AuthenticationServices

class GoogleAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {

    func signIn() async throws -> String {
        // 1. Generate PKCE code verifier + challenge
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)

        // 2. Build authorization URL
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: googleIosClientId),
            URLQueryItem(name: "redirect_uri", value: "com.googleusercontent.apps.\(reversedClientId):/oauthredirect"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        // 3. Present auth session
        let callbackURL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: "com.googleusercontent.apps.\(reversedClientId)"
            ) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? AuthError.cancelled) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        // 4. Extract authorization code from callback
        let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value

        // 5. Exchange code for ID token via your backend
        // POST /api/auth/google/callback { code, codeVerifier }
        return code!
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first ?? ASPresentationAnchor()
    }
}
```

**Alternative — Implicit grant (simpler, less secure)**: Use `response_type=token` to get an ID token directly in the redirect URL. Simpler but the token is exposed in the URL.

### 2.2 iOS/Flutter — google_sign_in SDK

Best for Flutter apps or when you want Google's native sign-in UI.

```dart
// pubspec.yaml
dependencies:
  google_sign_in: ^6.2.1

// Configuration: ios/Runner/Info.plist
// Add reversed client ID as a URL scheme:
// <string>com.googleusercontent.apps.YOUR_IOS_CLIENT_ID</string>
```

```dart
import 'package:google_sign_in/google_sign_in.dart';

class GoogleAuthService {
  // Use web client ID for serverAuthCode (backend exchange)
  // iOS client ID is auto-detected from Info.plist
  final _googleSignIn = GoogleSignIn(
    serverClientId: 'WEB_CLIENT_ID.apps.googleusercontent.com',
    scopes: ['email', 'profile'],
  );

  Future<String?> signIn() async {
    final account = await _googleSignIn.signIn();
    if (account == null) return null; // User cancelled

    final auth = await account.authentication;
    // auth.idToken — send to backend for verification
    // auth.serverAuthCode — alternative: backend exchanges for tokens
    return auth.idToken;
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
  }
}
```

**Key distinction**: `serverClientId` must be the **web** client ID, not the iOS one. The SDK uses this to request a `serverAuthCode` that your backend can exchange.

### 2.3 Next.js Web — NextAuth.js v5 (Auth.js)

```typescript
// auth.ts (root or src/)
import NextAuth from 'next-auth';
import Google from 'next-auth/providers/google';

export const { handlers, auth, signIn, signOut } = NextAuth({
  providers: [
    Google({
      clientId: process.env.GOOGLE_CLIENT_ID!,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET!,
    }),
  ],
  callbacks: {
    async jwt({ token, account }) {
      // On initial sign-in, exchange Google token for your backend JWT
      if (account?.id_token) {
        const backendTokens = await exchangeForBackendTokens(account.id_token);
        token.accessToken = backendTokens.accessToken;
        token.refreshToken = backendTokens.refreshToken;
        token.expiresAt = backendTokens.expiresAt;
      }
      // Proactive refresh (see Part 4)
      if (Date.now() > (token.expiresAt as number) - 60_000) {
        return await refreshBackendToken(token);
      }
      return token;
    },
    async session({ session, token }) {
      session.accessToken = token.accessToken as string;
      return session;
    },
  },
});

// app/api/auth/[...nextauth]/route.ts
export { handlers as GET, handlers as POST } from '@/auth';
```

```
# .env.local
GOOGLE_CLIENT_ID=816049546145-xxx.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-xxxxxxxxxx
NEXTAUTH_URL=https://yourdomain.com
NEXTAUTH_SECRET=your-random-secret
```

**Authorized redirect URI** in GCP console: `https://yourdomain.com/api/auth/callback/google`

### 2.4 Go Backend — ID Token Verification

Two approaches depending on your needs:

#### Approach A: Google's idtoken library (simplest)

```go
import "google.golang.org/api/idtoken"

func verifyGoogleIDToken(ctx context.Context, token string) (*idtoken.Payload, error) {
    // Validates signature, expiry, issuer, and audience
    payload, err := idtoken.Validate(ctx, token, googleWebClientID)
    if err != nil {
        // Try iOS client ID
        payload, err = idtoken.Validate(ctx, token, googleIOSClientID)
        if err != nil {
            return nil, fmt.Errorf("invalid Google ID token: %w", err)
        }
    }
    return payload, nil
}

// Extract user info from payload
func extractGoogleUser(payload *idtoken.Payload) GoogleUser {
    return GoogleUser{
        Sub:   payload.Subject,                          // Unique Google user ID
        Email: payload.Claims["email"].(string),         // User's email
        Name:  payload.Claims["name"].(string),          // Display name
    }
}
```

#### Approach B: Manual JWKS verification (no Google SDK dependency)

```go
import (
    "crypto/rsa"
    "encoding/base64"
    "encoding/json"
    "math/big"
    "net/http"
    "github.com/golang-jwt/jwt/v5"
)

const googleJWKSURL = "https://www.googleapis.com/oauth2/v3/certs"

type GoogleJWKS struct {
    Keys []GoogleJWK `json:"keys"`
}

type GoogleJWK struct {
    Kid string `json:"kid"`
    N   string `json:"n"`
    E   string `json:"e"`
}

// Cache JWKS keys (refresh every ~24h or on kid miss)
var (
    jwksCache     *GoogleJWKS
    jwksCacheTime time.Time
)

func getGooglePublicKey(kid string) (*rsa.PublicKey, error) {
    if jwksCache == nil || time.Since(jwksCacheTime) > 24*time.Hour {
        resp, err := http.Get(googleJWKSURL)
        if err != nil { return nil, err }
        defer resp.Body.Close()
        jwksCache = &GoogleJWKS{}
        json.NewDecoder(resp.Body).Decode(jwksCache)
        jwksCacheTime = time.Now()
    }

    for _, key := range jwksCache.Keys {
        if key.Kid == kid {
            return jwkToRSAPublicKey(key)
        }
    }
    return nil, fmt.Errorf("key %s not found", kid)
}

func verifyGoogleToken(tokenString string) (*jwt.Token, error) {
    return jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
        kid, ok := token.Header["kid"].(string)
        if !ok { return nil, fmt.Errorf("missing kid header") }
        return getGooglePublicKey(kid)
    }, jwt.WithValidMethods([]string{"RS256"}),
       jwt.WithIssuer("https://accounts.google.com"),
       jwt.WithAudience(googleWebClientID), // or check multiple audiences
    )
}
```

#### Multi-audience verification

Your backend must accept tokens from ALL your client IDs:

```go
func isValidAudience(aud string) bool {
    validAudiences := []string{
        os.Getenv("GOOGLE_CLIENT_ID"),     // Web
        os.Getenv("GOOGLE_IOS_CLIENT_ID"), // iOS
    }
    for _, valid := range validAudiences {
        if aud == valid { return true }
    }
    return false
}
```

---

## Part 3: Backend Auth Flow — Login to Token Issuance

Once Google verifies the user's identity, your backend takes over session management entirely.

### 3.1 Login Endpoint

```go
func HandleGoogleCallback(w http.ResponseWriter, r *http.Request) {
    var req struct {
        IDToken string `json:"idToken"`
    }
    json.NewDecoder(r.Body).Decode(&req)

    // 1. Verify Google ID token
    payload, err := verifyGoogleIDToken(r.Context(), req.IDToken)
    if err != nil {
        http.Error(w, "Invalid token", 401)
        return
    }

    // 2. Find or create user
    googleSub := payload.Subject
    email := payload.Claims["email"].(string)
    name := payload.Claims["name"].(string)

    user, err := findOrCreateUser(r.Context(), googleSub, email, name)
    if err != nil {
        http.Error(w, "Internal error", 500)
        return
    }

    // 3. Issue YOUR tokens (not Google's)
    accessToken := issueAccessToken(user.ID)   // JWT, HS256, 15-min TTL
    refreshToken := issueRefreshToken(user.ID)  // ULID, 30-day TTL, stored in DB

    // 4. Return tokens
    json.NewEncoder(w).Encode(map[string]string{
        "accessToken":  accessToken,
        "refreshToken": refreshToken,
        "userId":       user.ID,
    })
}
```

### 3.2 Provider Linking

Support multiple auth providers (Google + Apple) mapping to the same user account:

```
DynamoDB:
  PK: GOOGLE#{sub}    SK: LINK    → { userId: "01HX..." }
  PK: APPLE#{sub}     SK: LINK    → { userId: "01HX..." }
  PK: USER#{userId}   SK: PROFILE → { email, name, ... }
```

On Google login:
1. Look up `GOOGLE#{sub}` → found? Return existing user
2. Not found? Check if email matches existing user → link Google sub to that user
3. No match? Create new user + Google link

### 3.3 Access Token (JWT)

```go
func issueAccessToken(userID string) string {
    claims := jwt.MapClaims{
        "sub": userID,
        "iat": time.Now().Unix(),
        "exp": time.Now().Add(15 * time.Minute).Unix(), // Short-lived
    }
    token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
    signed, _ := token.SignedString([]byte(jwtSecret))
    return signed
}
```

### 3.4 Refresh Token (Stored in DynamoDB)

```go
func issueRefreshToken(userID string) RefreshToken {
    tokenID := ulid.Make().String()
    plaintext := generateSecureRandom(32) // crypto/rand
    hashed := sha256Hex(plaintext)
    familyID := ulid.Make().String()      // Links token chain

    rt := RefreshToken{
        PK:        "USER#" + userID,
        SK:        "REFRESH#" + tokenID,
        GSI1PK:    "REFRESH#" + hashed,
        GSI1SK:    "REFRESH",
        TokenID:   tokenID,
        UserID:    userID,
        HashedToken: hashed,
        FamilyID:  familyID,
        Status:    "ACTIVE",
        ExpiresAt: time.Now().Add(30 * 24 * time.Hour),
        TTL:       time.Now().Add(30 * 24 * time.Hour).Unix(),
    }
    // Store in DynamoDB
    return rt
}
```

**Key design**: Client receives the plaintext token. DB stores the SHA-256 hash. On refresh, hash the submitted token and look it up via GSI.

---

## Part 4: Long-Lived Sessions — Token Refresh & Rotation

This is the hardest part to get right. The core challenge: when the access token expires, multiple concurrent API requests all try to refresh simultaneously.

### 4.1 The Race Condition Problem

```
Timeline:
  t=0:    Access token expires
  t=1ms:  Request A gets 401, calls POST /auth/refresh with token X
  t=2ms:  Request B gets 401, calls POST /auth/refresh with token X
  t=50ms: Server processes A: delete token X, create token Y → 200
  t=51ms: Server processes B: look up token X → NOT FOUND → 401
  t=52ms: Client receives 401 from B → signs user out
```

### 4.2 Backend Fix: Atomic Rotation + Grace Period

**Stop deleting tokens. Mark them USED instead.**

```go
const refreshGracePeriod = 30 * time.Second

func HandleRefresh(w http.ResponseWriter, r *http.Request) {
    var req struct{ RefreshToken string `json:"refreshToken"` }
    json.NewDecoder(r.Body).Decode(&req)

    hashed := sha256Hex(req.RefreshToken)

    // 1. Look up token by hash (GSI)
    rt, err := db.GetRefreshTokenByHash(ctx, hashed)
    if err != nil || rt == nil {
        respond401(w, "FTW-130", "token_not_found")
        return
    }

    // 2. Check expiry
    if time.Now().After(rt.ExpiresAt) {
        respond401(w, "FTW-131", "token_expired")
        return
    }

    // 3. Check status
    switch rt.Status {
    case "REVOKED":
        respond401(w, "FTW-133", "token_revoked")
        return

    case "USED":
        if !rt.UsedAt.IsZero() && time.Since(rt.UsedAt) <= refreshGracePeriod {
            // Race condition! Issue fresh tokens in same family
            log.Warn("FTW-132: grace period hit")
            issueFreshTokens(w, r, rt.UserID, rt.FamilyID)
            return
        }
        // Reuse outside grace = potential attack
        log.Error("FTW-133: token reuse outside grace period")
        db.RevokeTokenFamily(ctx, rt.UserID, rt.FamilyID)
        respond401(w, "FTW-133", "token_reuse_blocked")
        return
    }

    // 4. ACTIVE token — attempt atomic rotation
    newRT := buildNewRefreshToken(rt.UserID, rt.FamilyID)

    err = db.RotateRefreshToken(ctx, rt, newRT)
    if err == ErrTokenAlreadyUsed {
        // Another request rotated first — re-read and check grace
        fresh, _ := db.GetRefreshTokenByID(ctx, rt.UserID, rt.TokenID)
        if fresh != nil && !fresh.UsedAt.IsZero() &&
            time.Since(fresh.UsedAt) <= refreshGracePeriod {
            issueFreshTokens(w, r, rt.UserID, rt.FamilyID)
            return
        }
        respond401(w, "FTW-130", "rotation_conflict")
        return
    }

    // 5. Success — return new tokens
    accessToken := issueAccessToken(rt.UserID)
    respondJSON(w, TokenResponse{
        AccessToken:  accessToken,
        RefreshToken: newRT.PlaintextToken,
    })
}
```

#### Atomic Rotation with DynamoDB TransactWriteItems

```go
func RotateRefreshToken(ctx context.Context, oldRT, newRT *RefreshToken) error {
    _, err := client.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
        TransactItems: []types.TransactWriteItem{
            {
                // Mark old token as USED (conditional on still being ACTIVE)
                Update: &types.Update{
                    TableName: aws.String(tableName),
                    Key: map[string]types.AttributeValue{
                        "PK": &types.AttributeValueMemberS{Value: oldRT.PK},
                        "SK": &types.AttributeValueMemberS{Value: oldRT.SK},
                    },
                    UpdateExpression: aws.String(
                        "SET #status = :used, usedAt = :now, replacedBy = :newId, #ttl = :ttl"),
                    ConditionExpression: aws.String(
                        "#status = :active OR attribute_not_exists(#status)"),
                    ExpressionAttributeNames: map[string]string{
                        "#status": "status",
                        "#ttl":    "ttl",
                    },
                    ExpressionAttributeValues: map[string]types.AttributeValue{
                        ":used":   &types.AttributeValueMemberS{Value: "USED"},
                        ":active": &types.AttributeValueMemberS{Value: "ACTIVE"},
                        ":now":    &types.AttributeValueMemberS{Value: time.Now().Format(time.RFC3339)},
                        ":newId":  &types.AttributeValueMemberS{Value: newRT.TokenID},
                        ":ttl":    &types.AttributeValueMemberN{Value: fmt.Sprintf("%d", time.Now().Add(time.Hour).Unix())},
                    },
                },
            },
            {
                // Create new token unconditionally
                Put: &types.Put{
                    TableName: aws.String(tableName),
                    Item:      marshalRefreshToken(newRT),
                },
            },
        },
    })

    if isConditionalCheckFailed(err) {
        return ErrTokenAlreadyUsed
    }
    return err
}
```

#### Token States and TTL

| Status | TTL | Meaning |
|--------|-----|---------|
| ACTIVE | Token expiry (30 days) | Normal, usable token |
| USED | UsedAt + 1 hour | Consumed but in grace period window |
| REVOKED | Now + 24 hours | Blocked, potential attack detected |

Enable DynamoDB TTL on the `ttl` attribute for automatic cleanup.

#### Token Families

Every token issued from a single login session shares a `familyId` (ULID). This enables chain revocation — if reuse is detected outside the grace period, revoke ALL tokens in that family.

### 4.3 iOS Client Fix: Token Refresh Coordinator

**Problem**: `@MainActor` does NOT prevent concurrent refreshes. `await` on network calls yields the actor, allowing a second refresh to start with the same token.

**Fix**: A Swift `actor` with a shared `Task` reference. All callers join the same in-flight refresh.

```swift
enum RefreshResult {
    case success
    case definitiveFailure   // 401 — token revoked/invalid, must sign out
    case transientFailure    // Network error — safe to retry later
}

actor TokenRefreshCoordinator {
    static let shared = TokenRefreshCoordinator()
    private var refreshTask: Task<RefreshResult, Never>?

    func ensureValidToken() async -> RefreshResult {
        // If refresh already in-flight, join it
        if let existingTask = refreshTask {
            return await existingTask.value
        }

        // Start new refresh
        let task = Task<RefreshResult, Never> {
            let result = await AuthService.shared.performRefresh()
            return result
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }
}
```

**Why this works**: The actor's serial executor makes the `if let existingTask` check-and-set atomic. `Task.value` is multi-awaitable — all concurrent callers get the same result.

#### Wire into API requests

```swift
func request<T: Decodable>(endpoint: String, method: String, ...) async throws -> T {
    // 1. Proactive refresh — prevent most 401s
    if authenticated && isAccessTokenExpiringSoon {
        let result = await TokenRefreshCoordinator.shared.ensureValidToken()
        if result == .success {
            // Update Authorization header with fresh token
        }
    }

    // 2. Make request...
    let (data, response) = try await session.data(for: urlRequest)

    // 3. On 401 — reactive refresh via coordinator
    if httpResponse.statusCode == 401 && authenticated {
        let result = await TokenRefreshCoordinator.shared.ensureValidToken()
        switch result {
        case .success:
            // Retry with new token
        case .definitiveFailure:
            signOut()
            throw APIServiceError.unauthorized
        case .transientFailure:
            throw APIServiceError.unauthorized
        }
    }
}
```

#### Proactive refresh (prevent 401s entirely)

```swift
var isAccessTokenExpiringSoon: Bool {
    guard let token = accessToken else { return true }

    // Decode JWT payload (base64url)
    let parts = token.split(separator: ".")
    guard parts.count == 3,
          let data = base64URLDecode(String(parts[1])),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = json["exp"] as? TimeInterval else {
        return true  // Conservative — trigger refresh on decode failure
    }

    return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 60
}
```

#### Critical: Refresh endpoint must bypass 401 retry

The refresh call itself must NOT go through the 401 retry path or it causes infinite recursion:

```swift
// performRefresh() uses requestDirect() — no 401 retry logic
func performRefresh() async -> RefreshResult {
    do {
        let response: RefreshResponse = try await APIService.shared.requestDirect(
            endpoint: "/auth/refresh",
            method: "POST",
            body: RefreshRequest(refreshToken: refreshToken),
            authenticated: false  // Refresh token IS the auth
        )
        accessToken = response.accessToken
        refreshToken = response.refreshToken
        return .success
    } catch APIServiceError.serverError(401, _) {
        return .definitiveFailure
    } catch {
        return .transientFailure
    }
}
```

### 4.4 Flutter/Dart Equivalent

```dart
class TokenRefreshCoordinator {
  static final instance = TokenRefreshCoordinator._();
  TokenRefreshCoordinator._();

  Future<RefreshResult>? _refreshFuture;

  Future<RefreshResult> ensureValidToken() async {
    // Join existing refresh if in-flight
    if (_refreshFuture != null) return _refreshFuture!;

    _refreshFuture = _performRefresh();
    try {
      return await _refreshFuture!;
    } finally {
      _refreshFuture = null;
    }
  }

  Future<RefreshResult> _performRefresh() async {
    try {
      final response = await apiClient.post('/auth/refresh',
          data: {'refreshToken': authStore.refreshToken});
      authStore.setTokens(response.accessToken, response.refreshToken);
      return RefreshResult.success;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return RefreshResult.definitiveFailure;
      return RefreshResult.transientFailure;
    }
  }
}
```

### 4.5 Next.js Web — JWT Callback Refresh

NextAuth handles refresh in the `jwt` callback:

```typescript
callbacks: {
  async jwt({ token, account }) {
    // Initial sign-in — exchange Google token for backend JWT
    if (account?.id_token) {
      const res = await fetch(`${BACKEND_URL}/auth/google/callback`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ idToken: account.id_token }),
      });
      const data = await res.json();
      token.accessToken = data.accessToken;
      token.refreshToken = data.refreshToken;
      token.expiresAt = Date.now() + 15 * 60 * 1000; // 15 min
    }

    // Proactive refresh — 60s before expiry
    if (Date.now() < (token.expiresAt as number) - 60_000) {
      return token; // Still valid
    }

    // Refresh
    try {
      const res = await fetch(`${BACKEND_URL}/auth/refresh`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refreshToken: token.refreshToken }),
      });
      if (!res.ok) throw new Error('Refresh failed');
      const data = await res.json();
      token.accessToken = data.accessToken;
      token.refreshToken = data.refreshToken;
      token.expiresAt = Date.now() + 15 * 60 * 1000;
    } catch {
      token.error = 'RefreshTokenError';
    }
    return token;
  },
}
```

---

## Part 5: Security Best Practices

### 5.1 Token Security

| Practice | Why |
|----------|-----|
| Hash refresh tokens before storing | DB breach doesn't expose usable tokens |
| Rotate refresh tokens on every use | Limits window for stolen tokens |
| Token families with chain revocation | Detect and revoke stolen refresh tokens |
| Short access token TTL (15 min) | Limits damage from stolen access tokens |
| Grace period for concurrent requests | Prevents false-positive revocation |

### 5.2 ID Token Verification Checklist

When verifying Google ID tokens on your backend:

- [ ] Verify signature via Google's JWKS endpoint (RS256)
- [ ] Check `iss` is `https://accounts.google.com` or `accounts.google.com`
- [ ] Check `aud` matches one of YOUR client IDs
- [ ] Check `exp` is in the future
- [ ] Cache JWKS keys (refresh on `kid` miss or every ~24h)
- [ ] Accept tokens from ALL your platform client IDs

### 5.3 Error Codes

Define clear error codes for auth failures to aid debugging:

| Code | Meaning | Client Action |
|------|---------|---------------|
| FTW-130 | Refresh token not found | Sign out (token deleted or never existed) |
| FTW-131 | Refresh token expired | Sign out (past 30-day TTL) |
| FTW-132 | Race resolved via grace period | Issue fresh tokens (log as warning) |
| FTW-133 | Token reuse outside grace period | Revoke family, sign out (potential attack) |

### 5.4 Monitoring

CloudWatch Insights queries for auth health:

```
# Race condition frequency
fields @timestamp, @message
| filter @message like /FTW-13/
| stats count() by error_code, bin(1h)
```

Success criteria:
- FTW-130 drops to zero (race condition eliminated)
- FTW-132 rare and decreasing (grace period catches shrink as clients update)
- FTW-133 should be zero (indicates attack, not race)

### 5.5 Deploy Sequence

**Backend first** — protects all users immediately including old app builds.
**Client second** — prevents the race client-side, reducing server-side grace period hits.

Both layers are independently deployable and independently valuable.

---

## Part 6: DynamoDB TTL for Token Cleanup

Enable TTL to automatically clean up expired tokens:

```typescript
// CDK
(table.node.defaultChild as dynamodb.CfnTable).addPropertyOverride(
  'TimeToLiveSpecification',
  { AttributeName: 'ttl', Enabled: true }
);
```

Set TTL values in your DB client:
- **ACTIVE** tokens: `TTL = ExpiresAt.Unix()` (30 days)
- **USED** tokens: `TTL = UsedAt + 1 hour`
- **REVOKED** tokens: `TTL = now + 24 hours`

---

## Quick Reference

### Recommended Stack per Platform

| Platform | Auth Library | Token Flow |
|----------|-------------|------------|
| iOS (Swift) | ASWebAuthenticationSession | PKCE code → backend exchange |
| iOS (Flutter) | google_sign_in SDK | ID token → backend verify |
| Web (Next.js) | NextAuth.js v5 / Auth.js | Server-side OAuth code flow |
| Backend (Go) | google.golang.org/api/idtoken | JWKS verification |

### Token Lifetimes

| Token | TTL | Storage |
|-------|-----|---------|
| Google ID token | ~1 hour | Never stored — used once at login |
| Your access token (JWT) | 15 minutes | Client memory only |
| Your refresh token | 30 days | Client keychain, DB (hashed) |

### Files to Create/Modify

When adding Google OAuth to a new project:

1. **GCP Console**: Create OAuth client IDs (web + iOS)
2. **CDK/Infra**: Add client IDs to Lambda environment
3. **Backend**: Add `/auth/google/callback` handler + JWKS verification
4. **Backend**: Add `/auth/refresh` handler with atomic rotation
5. **Backend**: Add provider link table entries (`GOOGLE#{sub}` → `LINK`)
6. **iOS**: Add GoogleSignIn config or ASWebAuthenticationSession flow
7. **iOS**: Add TokenRefreshCoordinator actor
8. **iOS**: Wire coordinator into API service 401 handling
9. **Web**: Configure NextAuth.js with Google provider + JWT refresh callback
