import Foundation
import Combine
import SwiftUI

final class DataStore: ObservableObject {
	private enum Defaults {
		static let springAnimation = Animation.spring(
			response: 0.4,
			dampingFraction: 0.6,
			blendDuration: 0.2
		)
	}

	private let userDefaults: UserDefaults

	@Published var data: [PrayerModel] = PrayerModel.defaultValues
	@Published var scales: [PrayerModel.ID: CGFloat] = [:]
	@Published var sortType: SortType {
		didSet {
			if sortType != oldValue {
				UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
			}
		}
	}

	@Published private(set) var sortedData: [PrayerModel] = []

	private let cloudStorage: CloudStorage
	private var cancellables: Set<AnyCancellable> = []

	init(
		userDefaults: UserDefaults = UserDefaults.standard,
		cloudStorage: CloudStorage = NSUbiquitousKeyValueStore.default
	) {
		self.userDefaults = userDefaults
		self.cloudStorage = cloudStorage

		if let sortStr = userDefaults.string(forKey: UserDefaultsKey.sortType.value) {
			sortType = SortType(rawValue: sortStr) ?? .default
		} else {
			sortType = .default
		}

		syncWithCloudStorage()

		sortedData = sort(data, basedOn: sortType)

		scales = calculateScales(basedOn: data)

		$data.sink { [weak self] newValue in
			guard let self else { return }

			save(newValue.toJSONString())

			withAnimation(Defaults.springAnimation) { [unowned self] in
				self.sortedData = self.sort(self.data, basedOn: self.sortType)
				self.scales = self.calculateScales(basedOn: newValue)
			}
		}
		.store(in: &cancellables)

		cloudStorage
			.publisher(for: UserDefaultsKey.data.value)
			.debounce(for: .milliseconds(300), scheduler: RunLoop.main)
			.sink { [weak self] newValue in
				if let cloudData = newValue {
					if let newModels = [PrayerModel].decode(using: cloudData) {
						self?.data = newModels
					}
				}
			}
			.store(in: &cancellables)

		$sortType.sink { [weak self] newValue in
			guard let self else { return }

			userDefaults.set(
				newValue.rawValue,
				forKey: UserDefaultsKey.sortType.value
			)

			withAnimation(Defaults.springAnimation) { [unowned self] in
				self.sortedData = self.sort(self.data, basedOn: newValue)
			}
		}
		.store(in: &cancellables)
	}

	private func syncWithCloudStorage() {
		let cloudTimestamp: Date = cloudStorage.value(for: UserDefaultsKey.timestamp.value) ?? .distantPast
		let localTimestamp: Date = userDefaults
			.value(forKey: UserDefaultsKey.timestamp.value) as? Date ?? .distantPast

		if
			let cloudData: String = cloudStorage
				.value(for: UserDefaultsKey.data.value),
			!cloudData.isEmpty,
			cloudTimestamp >= localTimestamp {
			// Update UserDefaults with the cloud value and timestamp
			userDefaults.set(cloudData, forKey: UserDefaultsKey.data.value)
			userDefaults.set(cloudTimestamp, forKey: UserDefaultsKey.timestamp.value)

			let models = [PrayerModel].decode(using: cloudData) ?? []
			if models.isEmpty {
				data = PrayerModel.defaultValues
			} else {
				data = models
			}
		} else if let localData: String = userDefaults
			.string(forKey: UserDefaultsKey.data.value), localTimestamp > cloudTimestamp {
			// Update cloud storage with the local value and timestamp
			cloudStorage.set(localData, forKey: UserDefaultsKey.data.value)
			cloudStorage.set(localTimestamp, forKey: UserDefaultsKey.timestamp.value)
			cloudStorage.synchronize()
		}
	}

	private func save(_ data: String?) {
		guard let data else {
			return
		}

		let now = Date()

		userDefaults.set(data, forKey: UserDefaultsKey.data.value)
		userDefaults.set(now, forKey: UserDefaultsKey.timestamp.value)

		cloudStorage.set(data, forKey: UserDefaultsKey.data.value)
		cloudStorage.set(now, forKey: UserDefaultsKey.timestamp.value)
		cloudStorage.synchronize()
	}

	private func sort(
		_ models: [PrayerModel],
		basedOn sortType: SortType
	) -> [PrayerModel] {
		return models.sorted {
			switch sortType {
			case .ascending:
				return $0.count < $1.count
			case .descending:
				return $0.count > $1.count
			case .default:
				return $0.intrinsicOrder < $1.intrinsicOrder
			}
		}
	}

	private func calculateScales(basedOn models: [PrayerModel]) -> [PrayerModel.ID: CGFloat] {
		var result: [PrayerModel.ID: CGFloat] = [:]

		models.forEach {
			result[$0.id] = max(1.0, min(CGFloat($0.count) * 0.1 + 1.0, BubbleViewConstants.ratio))
		}

		return result
	}

	func columnsCount(basedOn width: CGFloat) -> Int {
		let totalScales = Int(scales.values.reduce(0, +).rounded(.down))

		switch width {
		case 0..<375: return 2
		case 375..<750: return min(2, max(9 - totalScales, 2))
		case 750..<1024: return min(3, max(10 - totalScales, 3))
		case 1024..<1500: return min(4, max(11 - totalScales, 4))
		case 1500...: return min(5, max(12 - totalScales, 5))
		default: return 2
		}
	}

	func scale(for id: PrayerModel.ID) -> Binding<CGFloat> {
		Binding { [weak self] in
			self?.scales[id] ?? 1.0
		} set: { [weak self] newValue in
			self?.scales[id] = newValue
		}
	}

	func count(for id: PrayerModel.ID) -> Binding<Int> {
		Binding { [weak self] in
			self?.data.first {
				$0.id == id
			}?.count ?? 0
		} set: { [weak self] newValue in
			if let index = self?.data.firstIndex(where: { $0.id == id }) {
				self?.data[index].count = newValue
			}
		}
	}
}
