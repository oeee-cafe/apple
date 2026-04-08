import Foundation

class PostService {
    static let shared = PostService()

    private let apiClient = APIClient.shared

    private init() {}

    func fetchPublicPosts(offset: Int = 0, limit: Int = 18) async throws -> PostsResponse {
        let queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        return try await apiClient.fetch(
            path: "/api/v1/posts/public",
            queryItems: queryItems
        )
    }

    func fetchPostDetails(postId: String) async throws -> PostDetailResponse {
        return try await apiClient.fetch(
            path: "/api/v1/posts/\(postId)",
            queryItems: nil
        )
    }

    func fetchActiveCommunities() async throws -> ActiveCommunitiesResponse {
        return try await apiClient.fetch(
            path: "/api/v1/communities/active",
            queryItems: nil
        )
    }

    func fetchLatestComments() async throws -> RecentCommentsResponse {
        return try await apiClient.fetch(
            path: "/api/v1/comments/latest",
            queryItems: nil
        )
    }

    func fetchCommunityDetail(slug: String, offset: Int = 0, limit: Int = 18) async throws -> CommunityDetail {
        // Ensure slug has @ prefix
        let slugParam = slug.hasPrefix("@") ? slug : "@\(slug)"
        let queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return try await apiClient.fetch(
            path: "/api/v1/communities/\(slugParam)",
            queryItems: queryItems
        )
    }

    func fetchProfileDetail(loginName: String, offset: Int = 0, limit: Int = 18) async throws -> ProfileDetail {
        let queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return try await apiClient.fetch(
            path: "/api/v1/profiles/\(loginName)",
            queryItems: queryItems
        )
    }

    func fetchProfileFollowings(loginName: String, offset: Int = 0, limit: Int = 50) async throws -> ProfileFollowingsListResponse {
        let queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return try await apiClient.fetch(
            path: "/api/v1/profiles/\(loginName)/followings",
            queryItems: queryItems
        )
    }

    func fetchReactionsByEmoji(postId: String, emoji: String) async throws -> ReactorsResponse {
        // URL encode the emoji
        guard let encodedEmoji = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw NSError(domain: "PostService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode emoji"])
        }

        return try await apiClient.fetch(
            path: "/api/v1/posts/\(postId)/reactions/\(encodedEmoji)",
            queryItems: nil
        )
    }

    func fetchPostComments(postId: String, offset: Int = 0, limit: Int = 100) async throws -> CommentsListResponse {
        let queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        return try await apiClient.fetch(
            path: "/api/v1/posts/\(postId)/comments",
            queryItems: queryItems
        )
    }

    func postComment(postId: String, content: String, parentCommentId: String? = nil) async throws -> Comment {
        let request = CreateCommentRequest(content: content, parentCommentId: parentCommentId)
        return try await apiClient.post(
            path: "/api/v1/posts/\(postId)/comments",
            body: request
        )
    }

    func deleteComment(commentId: String) async throws {
        struct EmptyResponse: Codable {}
        let _: EmptyResponse = try await apiClient.delete(path: "/api/v1/comments/\(commentId)")
    }

    func deletePost(postId: String) async throws {
        let _: DeletePostResponse = try await apiClient.delete(path: "/api/v1/posts/\(postId)")
    }

    func editPost(postId: String, title: String, content: String, hashtags: String?, isSensitive: Bool, allowRelay: Bool) async throws {
        let request = EditPostRequest(
            title: title,
            content: content,
            hashtags: hashtags,
            isSensitive: isSensitive,
            allowRelay: allowRelay
        )
        try await apiClient.put(
            path: "/api/v1/posts/\(postId)",
            body: request
        )
    }

    func addReaction(postId: String, emoji: String) async throws -> ReactionResponse {
        // URL encode the emoji
        let encodedEmoji = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        return try await apiClient.post(
            path: "/api/v1/posts/\(postId)/reactions/\(encodedEmoji)",
            body: EmptyRequest()
        )
    }

    func removeReaction(postId: String, emoji: String) async throws -> ReactionResponse {
        // URL encode the emoji
        let encodedEmoji = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        return try await apiClient.delete(path: "/api/v1/posts/\(postId)/reactions/\(encodedEmoji)")
    }
}

// MARK: - Reaction Response
struct ReactionResponse: Codable {
    let reactions: [ReactionCount]
}

// MARK: - Follow Response
struct FollowResponse: Codable {
    // Empty response structure - backend returns 200 OK with no body
}

extension PostService {
    // MARK: - Follow/Unfollow Methods

    func followProfile(loginName: String) async throws {
        try await apiClient.post(path: "/api/v1/profiles/\(loginName)/follow")
    }

    func unfollowProfile(loginName: String) async throws {
        try await apiClient.post(path: "/api/v1/profiles/\(loginName)/unfollow")
    }

    // MARK: - Move Post Methods

    /// Fetch list of communities that a post can be moved to
    func fetchMovableCommunities(postId: String) async throws -> MovableCommunitiesResponse {
        return try await apiClient.fetch(
            path: "/api/v1/posts/\(postId)/movable-communities",
            queryItems: nil
        )
    }

    /// Move a post to a different community (or to personal posts if communityId is nil)
    func movePostToCommunity(postId: String, communityId: String?) async throws {
        let request = MoveCommunityRequest(communityId: communityId)
        try await apiClient.put(
            path: "/api/v1/posts/\(postId)/community",
            body: request
        )
    }

    // MARK: - Report Methods

    /// Report a post
    func reportPost(postId: String, description: String) async throws {
        let request = ReportPostRequest(description: description)
        struct ReportPostResponse: Codable {
            let message: String
        }
        let _: ReportPostResponse = try await apiClient.post(
            path: "/api/v1/posts/\(postId)/report",
            body: request
        )
    }

    /// Report a profile
    func reportProfile(loginName: String, description: String) async throws {
        let request = ReportPostRequest(description: description)
        struct ReportProfileResponse: Codable {
            let message: String
        }
        let _: ReportProfileResponse = try await apiClient.post(
            path: "/api/v1/profiles/\(loginName)/report",
            body: request
        )
    }
}

// MARK: - Report Request
struct ReportPostRequest: Codable {
    let description: String
}
