//
//  HomeViewModel.swift
//  GroupIn
//
//  Placeholder ViewModel scaffold. Real logic lands when services are wired up.
//

import Foundation
import Observation

@Observable
final class HomeViewModel {
    var isLoading: Bool = false
    var errorMessage: String?
}
