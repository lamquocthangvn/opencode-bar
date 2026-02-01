import Foundation
import Combine

/// ViewModel managing multi-provider usage state
/// Extracts state management from StatusBarController for modern SwiftUI architecture
/// Uses ObservableObject for macOS 13.0+ compatibility
@MainActor
final class ProviderViewModel: ObservableObject {
    // MARK: - State Properties
    
    /// Current provider results from last fetch
    @Published var providerResults: [ProviderIdentifier: ProviderResult] = [:]
    
    /// Providers currently being fetched (for loading indicators)
    @Published var loadingProviders: Set<ProviderIdentifier> = []
    
    /// Last error message from fetch operations
    @Published var lastError: String?
    
    /// Timestamp of last successful update
    @Published var lastUpdated: Date?
    
    // MARK: - Dependencies
    
    private let providerManager = ProviderManager.shared
    
    // MARK: - Public API
    
    /// Refreshes all provider data
    /// - Note: Updates loadingProviders during fetch for UI loading states
    func refresh() async {
        var enabledProviders: [ProviderIdentifier] = []
        for identifier in ProviderIdentifier.allCases {
            if await providerManager.getProvider(for: identifier) != nil {
                enabledProviders.append(identifier)
            }
        }
        loadingProviders = Set(enabledProviders)
        
        // Fetch all providers in parallel
        let results = await providerManager.fetchAll()
        
        // Update state
        providerResults = results
        lastUpdated = Date()
        lastError = nil
        totalOverageCost = await providerManager.calculateTotalOverageCost(from: providerResults)
        quotaAlerts = await providerManager.getQuotaAlerts(from: providerResults)
        
        // Clear loading state
        loadingProviders.removeAll()
    }
    
    // MARK: - Computed Properties for UI
    
    /// Filters quota-based providers from current results
    var quotaProviders: [ProviderResult] {
        providerResults.values.filter { 
            if case .quotaBased = $0.usage { return true }
            return false
        }
    }
    
    /// Filters pay-as-you-go providers from current results
    var paygProviders: [ProviderResult] {
        providerResults.values.filter {
            if case .payAsYouGo = $0.usage { return true }
            return false
        }
    }
    
    /// Calculates total overage cost across all pay-as-you-go providers
    @Published private(set) var totalOverageCost: Double = 0.0
    
    /// Returns providers with quota below 20% threshold
    /// - Returns: Array of (identifier, remaining percentage) tuples
    @Published private(set) var quotaAlerts: [(ProviderIdentifier, Double)] = []
}
