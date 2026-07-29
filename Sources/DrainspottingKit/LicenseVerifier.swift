import Foundation
import CryptoKit

/// Verifies license keys issued by alexcoulombepresents.com's commerce
/// backend (Stripe checkout -> Ed25519-signed key, see that repo's
/// `lib/commerce/license.ts`, which this mirrors exactly).
///
/// Key format: `base64url(JSON payload) + "." + base64url(Ed25519 signature)`.
/// Deliberately not a JWT — the whole point on both ends is a short,
/// dependency-free verifier. Verification is fully offline: no network call,
/// ever. That's a better fit for Drainspotting's "nothing leaves your Mac"
/// story than the old Gumroad flow (which needed one live API call).
public enum LicenseVerifier {

    public struct LicensePayload: Codable, Equatable {
        public let sku: String
        public let tier: String
        public let seats: Int
        public let licenseeEmail: String
        public let majorVersion: Int
        public let updatesUntil: String // ISO 8601 date
        public let issuedAt: String // ISO 8601 date

        enum CodingKeys: String, CodingKey {
            case sku, tier, seats
            case licenseeEmail = "licensee_email"
            case majorVersion = "major_version"
            case updatesUntil = "updates_until"
            case issuedAt = "issued_at"
        }
    }

    public enum VerifyError: Error, Equatable {
        case malformedKey
        case badEncoding
        case invalidPublicKey
        case signatureMismatch
        case wrongProduct(expected: String, found: String)
    }

    /// alexcoulombepresents.com's Ed25519 public key for Drainspotting
    /// licenses (SPKI PEM, not secret — this is meant to ship in the app).
    /// Rotated 2026-07-29 when Drainspotting moved onto this signing system;
    /// the corresponding private key lives only in that project's Vercel env.
    public static let publicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MCowBQYDK2VwAyEAZ/RVlKOFT7jzNQnWnZfWUfqdkpS21fdriDJp9TOIVqQ=
    -----END PUBLIC KEY-----
    """

    static let expectedSKU = "drainspotting"

    /// RFC 8410 Ed25519 SubjectPublicKeyInfo has a fixed 12-byte prefix (no
    /// algorithm parameters to vary) followed by the raw 32-byte key —
    /// verified against a real generated keypair rather than assumed.
    private static let spkiPrefixLength = 12

    static func rawPublicKey(fromPEM pem: String) -> Data? {
        let lines = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }
        guard let der = Data(base64Encoded: lines.joined()), der.count == 44 else { return nil }
        return der.dropFirst(spkiPrefixLength)
    }

    /// Verifies a license key against the embedded public key. Returns the
    /// decoded payload on success. Does not check `updates_until` — that's a
    /// display/entitlement concern for the caller, not a validity concern:
    /// an expired-updates license is still a genuine, honestly-purchased key.
    public static func verify(_ key: String) -> Result<LicensePayload, VerifyError> {
        verify(key, publicKeyPEM: publicKeyPEM)
    }

    static func verify(_ key: String, publicKeyPEM pem: String) -> Result<LicensePayload, VerifyError> {
        let parts = key.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 2 else { return .failure(.malformedKey) }

        guard let bodyData = Data(base64URLEncoded: String(parts[0])),
              let sigData = Data(base64URLEncoded: String(parts[1])) else {
            return .failure(.badEncoding)
        }
        guard let rawKey = rawPublicKey(fromPEM: pem),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            return .failure(.invalidPublicKey)
        }
        guard publicKey.isValidSignature(sigData, for: bodyData) else {
            return .failure(.signatureMismatch)
        }
        guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: bodyData) else {
            return .failure(.badEncoding)
        }
        guard payload.sku == expectedSKU else {
            return .failure(.wrongProduct(expected: expectedSKU, found: payload.sku))
        }
        return .success(payload)
    }
}

extension Data {
    /// `base64url` (RFC 4648 §5): `-`/`_` instead of `+`/`/`, no padding.
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = data
    }
}
