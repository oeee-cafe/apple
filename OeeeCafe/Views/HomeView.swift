import SwiftUI

struct DraftPostIdentifier: Identifiable {
    let id = UUID()
    let postId: String
    let communityId: String?
    let imageUrl: String
}

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var navigationCoordinator: NavigationCoordinator
    @State private var showSettings = false
    @State private var showDimensionPicker = false
    @State private var canvasDimensions: CanvasDimensions?
    @State private var shouldNavigateToPost = false
    @State private var navigateToPost: String?
    @State private var shouldNavigateToProfile = false
    @State private var navigateToProfile: String?
    @State private var draftPostToPublish: DraftPostIdentifier?

    private let columns = Constants.postGridColumns

    var body: some View {
        NavigationStack {
            ScrollView {
                if viewModel.isLoading && viewModel.posts.isEmpty {
                    LoadingStateView(message: "common.loading".localized)
                        .padding(.top, 100)
                } else if let error = viewModel.error, viewModel.posts.isEmpty {
                    ErrorStateView(error: error) {
                        Task {
                            await viewModel.loadInitial()
                        }
                    }
                    .padding(.top, 100)
                } else {
                    VStack(spacing: 24) {
                        // Active Communities Section
                        if !viewModel.communities.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("home.active_communities".localized)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .padding(.horizontal)

                                ForEach(viewModel.communities) { community in
                                    CommunityCard(community: community)
                                        .padding(.horizontal)
                                }
                            }
                            .padding(.top, 8)
                        }

                        // Recent Comments Section
                        if !viewModel.comments.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("home.recent_comments".localized)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .padding(.horizontal)

                                ForEach(viewModel.comments) { comment in
                                    RecentCommentCard(comment: comment)
                                        .padding(.horizontal)
                                }
                            }
                        }

                        // Posts Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("home.recent_posts".localized)
                                .font(.title2)
                                .fontWeight(.bold)
                                .padding(.horizontal)

                            LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(viewModel.posts) { post in
                            NavigationLink(destination: PostDetailView(postId: post.id)) {
                                PostGridItem(post: post)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                // Load more when we reach near the end and there's more to load
                                if let lastPost = viewModel.posts.last,
                                   post.id == lastPost.id,
                                   viewModel.hasMore,
                                   !viewModel.isLoadingMore {
                                    Task {
                                        await viewModel.loadMore()
                                    }
                                }
                            }
                        }

                                // Loading indicator for pagination
                                if viewModel.isLoadingMore {
                                    HStack {
                                        Spacer()
                                        ProgressView()
                                            .padding()
                                        Spacer()
                                    }
                                    .gridCellColumns(3)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
            }
            .navigationTitle("home.title".localized)
            .refreshable {
                await Task { @MainActor in
                    await viewModel.refresh()
                }.value
            }
            .toolbar {
                AppToolbar(authService: authService, showSettings: $showSettings, showDimensionPicker: $showDimensionPicker)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showDimensionPicker) {
                CanvasDimensionPicker(
                    onDimensionsSelected: { width, height, tool in
                        showDimensionPicker = false
                        // Use a small delay to ensure the sheet is dismissed before showing fullScreenCover
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            canvasDimensions = CanvasDimensions(width: width, height: height, tool: tool)
                        }
                    },
                    onCancel: {
                        showDimensionPicker = false
                    },
                    backgroundColor: nil,
                    foregroundColor: nil
                )
            }
            .fullScreenCover(item: $canvasDimensions) { dimensions in
                DrawWebView(
                    width: dimensions.width,
                    height: dimensions.height,
                    tool: dimensions.tool
                ) { postId, communityId, imageUrl in
                    Logger.debug("Drawing completed: postId=\(postId), communityId=\(communityId ?? "nil"), imageUrl=\(imageUrl)", category: Logger.app)
                    draftPostToPublish = DraftPostIdentifier(
                        postId: postId,
                        communityId: communityId,
                        imageUrl: imageUrl
                    )
                    canvasDimensions = nil
                }
            }
            .sheet(item: $draftPostToPublish) { draft in
                DraftPostView(
                    postId: draft.postId,
                    communityId: draft.communityId,
                    imageUrl: draft.imageUrl,
                    onPublished: {
                        draftPostToPublish = nil
                        navigateToPost = draft.postId
                        shouldNavigateToPost = true
                    },
                    onDeleted: {
                        draftPostToPublish = nil
                    },
                    onCancel: {
                        draftPostToPublish = nil
                    }
                )
            }
            .navigationDestination(isPresented: $shouldNavigateToPost) {
                if let postId = navigateToPost {
                    PostDetailView(postId: postId)
                }
            }
            .navigationDestination(isPresented: $shouldNavigateToProfile) {
                if let loginName = navigateToProfile {
                    ProfileView(loginName: loginName)
                }
            }
            .onChange(of: navigationCoordinator.pendingNavigation) { _, newValue in
                // Handle deep link navigation from push notifications
                guard let pending = newValue else { return }

                switch pending {
                case .post(let id):
                    navigateToPost = id
                    shouldNavigateToPost = true
                case .profile(let loginName):
                    navigateToProfile = loginName
                    shouldNavigateToProfile = true
                default:
                    // Other navigation types are handled by other tabs
                    break
                }

                // Clear the pending navigation after handling
                navigationCoordinator.clearPendingNavigation()
            }
        }
        .task {
            await viewModel.loadInitial()
        }
    }
}

#Preview {
    HomeView()
}
