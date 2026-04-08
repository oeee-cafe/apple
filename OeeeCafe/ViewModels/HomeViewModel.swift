import Foundation
import Combine

@MainActor
class HomeViewModel: ObservableObject {
    @Published var posts: [Post] = []
    @Published var communities: [ActiveCommunity] = []
    @Published var comments: [RecentComment] = []
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var isLoadingMore = false
    @Published var hasMore = true
    @Published var error: String?

    private let postService = PostService.shared
    private var currentOffset = 0

    func loadInitial() async {
        // Don't reload if we already have data or if currently refreshing
        guard !isLoading && !isRefreshing && posts.isEmpty else { return }

        isLoading = true
        error = nil
        currentOffset = 0

        do {
            // Fetch all data simultaneously
            async let postsResponse = postService.fetchPublicPosts(offset: 0)
            async let communitiesResponse = postService.fetchActiveCommunities()
            async let commentsResponse = postService.fetchLatestComments()

            let (postsResult, communitiesResult, commentsResult) = try await (postsResponse, communitiesResponse, commentsResponse)

            posts = postsResult.posts
            hasMore = postsResult.pagination.hasMore
            currentOffset = postsResult.pagination.offset
            communities = communitiesResult.communities
            comments = commentsResult.comments
        } catch {
            self.error = "Failed to load data: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func loadMore() async {
        guard !isLoadingMore && !isLoading && hasMore else { return }

        isLoadingMore = true

        do {
            let response = try await postService.fetchPublicPosts(offset: currentOffset)
            posts.append(contentsOf: response.posts)
            hasMore = response.pagination.hasMore
            currentOffset = response.pagination.offset
        } catch {
            self.error = "Failed to load more posts: \(error.localizedDescription)"
        }

        isLoadingMore = false
    }

    func refresh() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        error = nil
        currentOffset = 0

        do {
            // Fetch all data simultaneously
            async let postsResponse = postService.fetchPublicPosts(offset: 0)
            async let communitiesResponse = postService.fetchActiveCommunities()
            async let commentsResponse = postService.fetchLatestComments()

            let (postsResult, communitiesResult, commentsResult) = try await (postsResponse, communitiesResponse, commentsResponse)

            posts = postsResult.posts
            hasMore = postsResult.pagination.hasMore
            currentOffset = postsResult.pagination.offset
            communities = communitiesResult.communities
            comments = commentsResult.comments
        } catch {
            self.error = "Failed to load data: \(error.localizedDescription)"
        }

        isRefreshing = false
    }
}
