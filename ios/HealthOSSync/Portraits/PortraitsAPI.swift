import Foundation

// Portraits (server/portraits.ts, shared/portraits.ts): private reference photos, and likenesses made from one in the
// healthOS style on an OpenAI key, the person's own or the server's. A reference is never shown on the dashboard.
// Onboarding's first step and Profile's portrait studio both add references here. Images are fetched into memory
// only, never into the ProfileImages cache or onto disk.

/// The server's limits (shared/portraits.ts).
enum PortraitLimits {
    static let maxReferences = 5
    /// Base64 characters, a little under Vercel's 4.5 MB request limit.
    static let maxReferenceBase64 = 4_400_000
    /// A reference's longest side, in pixels: the phone shrinks it to this (PhotoPipeline.reference).
    static let maxReferenceEdge = 1600
    /// Generated portraits kept per person: delete one to make another.
    static let maxGenerated = 20
    /// Portraits a person can make in a day (UTC).
    static let perDay = 10
}

/// One reference photo or generated portrait (shared/portraits.ts Portrait).
struct Portrait: Codable, Identifiable, Equatable {
    let id: String
    /// "reference" | "generated"
    let kind: String
    /// "pending" | "ready" | "failed"
    var status: String
    var mime: String?
    var width: Double?
    var height: Double?
    var bytes: Double?
    /// For a generated portrait, the reference it came from.
    var referenceId: String?
    /// Why making it failed, in plain words; "" otherwise.
    var error: String?
    var createdAt: Double?

    var isReference: Bool { kind == "reference" }
}

/// GET /api/portraits: every reference and portrait, `chosen` the generated one in use, and whether one can be made
/// now (an OpenAI key, the person's or the server's).
struct PortraitList: Decodable, Equatable {
    @LossyArray var portraits: [Portrait]
    let chosen: String?
    @Lossy var canGenerate: Bool?

    var references: [Portrait] { portraits.filter(\.isReference) }
}

/// POST /api/portraits/reference and /generate: the photo kept, or the portrait being made.
struct PortraitCreated: Decodable {
    let portrait: Portrait
}

extension APIClient {
    /// GET /api/portraits; nil from a server older than portraits.
    func portraits() async throws -> PortraitList? { try await optional("/portraits") }

    /// Keeps a reference photo (POST /api/portraits/reference): a JPEG already shrunk and turned upright on the phone
    /// (PhotoPipeline.reference), sent as base64. The answer is the photo as kept, with its id. The server refuses a
    /// sixth (409) or one too large (413), in its own words.
    func addReference(_ photo: PreparedPhoto) async throws -> Portrait {
        // About 4.4 MB at most: longer than the usual 30 s on a slow connection.
        let created: PortraitCreated = try await sendJSON("POST", "/portraits/reference",
                                                          ["image": photo.base64, "width": photo.width, "height": photo.height], timeout: 90)
        return created.portrait
    }

    /// Deletes a reference photo or a portrait (DELETE /api/portraits/:id); the answer is the list as it is now. One in
    /// use stops being chosen; the profile photo made from it stays. Its 404 ("That photo is already gone.") is the
    /// route's own, never an older server's.
    func deletePortrait(id: String) async throws -> PortraitList {
        let data = try await request("/portraits/\(Self.pathPart(id))", method: "DELETE")
        return try JSONDecoder().decode(PortraitList.self, from: data)
    }

    /// Starts a portrait from a reference (POST /api/portraits/generate, answered 202): it's made in the background, and
    /// the list says ready or failed. Refused in the server's words: no key (409), one already being made (409), 20
    /// kept (409), the day's 10 made (429), the reference gone (404).
    func generatePortrait(referenceId: String) async throws -> Portrait {
        let created: PortraitCreated = try await sendJSON("POST", "/portraits/generate", ["referenceId": referenceId])
        return created.portrait
    }

    /// Marks a ready portrait as the one in use (POST /api/portraits/:id/choose), once it's been saved as the profile
    /// photo; the answer is the list as it is now.
    func choosePortrait(id: String) async throws -> PortraitList {
        try await sendJSON("POST", "/portraits/\(Self.pathPart(id))/choose")
    }

    /// One photo's image (GET /api/portraits/:id/image), to its owner only, sent private and no-store: a JPEG reference,
    /// a WebP or PNG portrait. Held in memory by whoever asked, never written to disk. Its 404 means that one is gone.
    func portraitImage(id: String) async throws -> Data {
        try await request("/portraits/\(Self.pathPart(id))/image")
    }

    /// An id as one path segment, as the web's encodeURIComponent makes it.
    static func pathPart(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? id
    }
}

extension Dashboard {
    /// The person's portraits; nil from a server without them. Tells Availability whether one can be made.
    func portraits() async throws -> PortraitList? {
        let list = try await fetch { try await $0.portraits() }
        if let can = list?.canGenerate { availability.heard(canGeneratePortraits: can) }
        return list
    }

    /// Keeps a reference photo (onboarding's first step, the portrait studio).
    func addReference(_ photo: PreparedPhoto) async throws -> Portrait {
        try await fetch { try await $0.addReference(photo) }
    }

    /// Deletes a reference photo or a portrait: onboarding's Change (after the new one is kept) and Remove, and the
    /// portrait studio's Delete. Answers with the list as it is now, which tells Availability whether one can be made.
    @discardableResult
    func deletePortrait(id: String) async throws -> PortraitList {
        let list = try await fetch { try await $0.deletePortrait(id: id) }
        if let can = list.canGenerate { availability.heard(canGeneratePortraits: can) }
        return list
    }

    /// Starts a portrait from a reference (the portrait studio's Make my portrait).
    func generatePortrait(referenceId: String) async throws -> Portrait {
        try await fetch { try await $0.generatePortrait(referenceId: referenceId) }
    }

    /// Marks a portrait as the one in use, after it became the profile photo. Answers with the list, which tells
    /// Availability whether one can be made.
    func choosePortrait(id: String) async throws -> PortraitList {
        let list = try await fetch { try await $0.choosePortrait(id: id) }
        if let can = list.canGenerate { availability.heard(canGeneratePortraits: can) }
        return list
    }

    /// One photo's image, into memory only (the portrait studio's thumbnails, and Use this portrait).
    func portraitImage(id: String) async throws -> Data {
        try await fetch { try await $0.portraitImage(id: id) }
    }
}
