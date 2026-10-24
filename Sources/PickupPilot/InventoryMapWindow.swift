import MapKit
import PilotCore
import SwiftUI

struct InventoryMapWindow: View {
    @Bindable var model: PilotModel
    var rendersMap = true
    @Environment(\.scenePhase) private var scenePhase

    private var presentation: InventoryMapPresentation {
        InventoryMapPresentation(stores: model.inventoryStores, variants: model.variants,
                                 selectedVariantIDs: model.preferences.selectedVariantIDs,
                                 availability: model.inventoryAvailability, isStale: model.inventoryDataIsStale,
                                 distance: model.distance, travelTime: model.travelTime)
    }

    var body: some View {
        InventoryMapContent(presentation: presentation, locationTitle: model.locationQuery,
                            origin: model.inventoryOriginCoordinate,
                            isRunning: model.inventoryMonitor.isRunning, isRefreshing: model.inventoryMonitor.isRefreshing,
                            lastCheck: model.inventoryMonitor.lastCheck, lastError: model.inventoryMonitor.lastError ?? model.inventorySetupError,
                            nextCheck: model.inventoryMonitor.nextCheck, checkCount: model.inventoryMonitor.checkCount,
                            refreshInterval: model.inventoryMonitor.refreshInterval,
                            alertSummary: model.inventoryAlerts.authorizationSummary,
                            notificationsEnabled: model.inventoryAlerts.notificationsEnabled,
                            deliveryDetails: model.inventoryAlerts.deliveryDetails,
                            unreadCount: model.inventoryAlerts.unreadCount, notificationError: model.inventoryAlerts.lastError,
                            refresh: { Task { await model.refreshInventory() } },
                            setRefreshInterval: model.setInventoryRefreshInterval,
                            enableAlerts: { Task { await model.inventoryAlerts.requestAuthorization() } },
                            acknowledge: { Task { await model.inventoryAlerts.acknowledge() } },
                            configurationBusy: model.busy || model.locationService.requesting,
                            rendersMap: rendersMap)
            .safeAreaInset(edge: .top, spacing: 0) { InventoryMapSetupControls(model: model) }
            .task { await model.inventoryAlerts.refreshAuthorization() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.inventoryAlerts.refreshAuthorization() } }
            }
            .frame(minWidth: 950, minHeight: 680)
            .navigationTitle("Apple Store inventory")
            .alert("Pickup Pilot", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

/// Independent of network, Keychain and checkout so the real controls can be rendered with synthetic data.
struct InventoryMapContent: View {
    let presentation: InventoryMapPresentation
    let locationTitle: String
    let origin: Coordinate?
    let isRunning: Bool
    let isRefreshing: Bool
    let lastCheck: Date?
    let lastError: String?
    let nextCheck: Date?
    let checkCount: Int
    let refreshInterval: TimeInterval
    let alertSummary: String
    let notificationsEnabled: Bool
    let deliveryDetails: String
    let unreadCount: Int
    let notificationError: String?
    let refresh: () -> Void
    let setRefreshInterval: (TimeInterval) -> Void
    let enableAlerts: () -> Void
    let acknowledge: () -> Void
    var configurationBusy = false
    /// Rendering fixtures use this to avoid loading map tiles or invoking location services.
    var rendersMap = true
    @State private var selectedStoreID: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var refreshSeconds = 1

    private var cameraSeed: InventoryMapCameraSeed {
        let coordinates = presentation.mappedStores.compactMap(\.coordinate) + [origin].compactMap { $0?.isValid == true ? $0 : nil }
        return InventoryMapCameraSeed(location: locationTitle,
                               coordinates: Set(coordinates).sorted { left, right in
                                   left.latitude == right.latitude ? left.longitude < right.longitude : left.latitude < right.latitude
                               })
    }

    private var observationStatus: String {
        if isRunning { return "Watching automatically" }
        if locationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a location" }
        if presentation.configurations.isEmpty { return "Choose products" }
        return configurationBusy ? "Loading inventory" : "Waiting for inventory"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let lastError {
                Label("Latest check failed: \(lastError). Previous results remain visible until a successful response.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
            }
            HSplitView {
                mapPane.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                storePane.frame(minWidth: 300, idealWidth: 340, maxWidth: 390, maxHeight: .infinity)
            }
            Divider()
            alertBar
        }
        .onChange(of: refreshInterval, initial: true) { _, interval in
            let seconds = interval.isFinite ? Int(min(3600, max(1, interval.rounded()))) : 1
            if refreshSeconds != seconds { refreshSeconds = seconds }
        }
        .onChange(of: refreshSeconds) { _, seconds in
            let clamped = min(3600, max(1, seconds))
            if clamped != seconds { refreshSeconds = clamped }
            if TimeInterval(clamped) != refreshInterval { setRefreshInterval(TimeInterval(clamped)) }
        }
        .task(id: cameraSeed) { fitNearbyStores() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Text("Nearby Apple inventory").font(.title2.bold())
                        Label(observationStatus, systemImage: isRunning ? "dot.radiowaves.left.and.right" : "clock")
                            .font(.caption.weight(.semibold)).foregroundStyle(isRunning ? Color.green : .secondary)
                    }
                    Text(locationTitle.isEmpty ? "Choose a location to find nearby stores" : "\(presentation.stores.count) nearby \(presentation.stores.count == 1 ? "store" : "stores") · \(locationTitle)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Refresh now", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(configurationBusy || isRefreshing || presentation.configurations.isEmpty || locationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("inventory-refresh-now")
            }
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Refresh every").font(.callout)
                    TextField("Refresh interval in seconds", value: $refreshSeconds, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 54).monospacedDigit()
                        .accessibilityIdentifier("inventory-refresh-seconds")
                    Text(refreshSeconds == 1 ? "second" : "seconds").font(.callout)
                    Stepper("Refresh interval", value: $refreshSeconds, in: 1...3600)
                        .labelsHidden().accessibilityLabel("Refresh interval in seconds")
                }.fixedSize()
                Divider().frame(height: 18)
                if isRefreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Checking Apple inventory")
                    Text("Checking Apple…").font(.caption).foregroundStyle(.secondary)
                } else if let lastCheck {
                    Text("Checked \(lastCheck, format: .dateTime.hour().minute().second())")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("No successful check yet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text("\(checkCount) checks").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if isRunning, let nextCheck {
                    Text("Next \(nextCheck, format: .dateTime.hour().minute().second())")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    @ViewBuilder private var mapPane: some View {
        if rendersMap, !presentation.mappedStores.isEmpty {
            Map(position: $camera, selection: $selectedStoreID) {
                if let origin, origin.isValid {
                    Marker("Search origin", systemImage: "location.circle", coordinate: origin.mapCoordinate).tint(.blue)
                }
                ForEach(presentation.mappedStores) { store in
                    if let coordinate = store.coordinate {
                        Annotation(store.retailer.name, coordinate: coordinate.mapCoordinate, anchor: .bottom) {
                            VStack(spacing: 3) {
                                InventoryMapBadge(store: store, selected: selectedStoreID == store.id)
                                    .background(.regularMaterial, in: .capsule)
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title2).foregroundStyle(selectedStoreID == store.id ? Color.accentColor : Color.primary)
                                    .background(.background, in: .circle)
                            }
                            .accessibilityLabel(store.accessibilitySummary)
                        }.tag(store.id)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls { MapCompass(); MapScaleView(); MapZoomStepper() }
            .overlay(alignment: .topLeading) { mapLegend.padding(14) }
            .overlay(alignment: .bottomTrailing) {
                Button("Fit nearby stores", systemImage: "arrow.up.left.and.arrow.down.right", action: fitNearbyStores)
                    .buttonStyle(.bordered).padding(14).background(.regularMaterial, in: .rect(cornerRadius: 10)).padding(12)
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
                Text(rendersMap ? "Store map will appear here" : "Synthetic map preview").font(.title3.weight(.semibold))
                Text(rendersMap ? "Find nearby stores with map coordinates. Every returned store is still listed beside the map." : "Map tiles and location services are disabled in this rendering fixture.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
                mapLegend
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private var mapLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(presentation.storesWithPickup) \(presentation.storesWithPickup == 1 ? "store" : "stores") with pickup", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.green)
            Text("Badges count configurations, not units.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.regularMaterial, in: .rect(cornerRadius: 10))
    }

    private var storePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Watching \(presentation.configurations.count) \(presentation.configurations.count == 1 ? "configuration" : "configurations")").font(.headline)
                if presentation.configurations.isEmpty {
                    Text("Choose at least one product configuration to see inventory.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(presentation.configurations) { configuration in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(configuration.name).font(.callout).lineLimit(2)
                                    Text(configuration.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 100)
                }
                Text("Apple reports pickup eligibility. Missing responses are unverified.")
                    .font(.caption).foregroundStyle(.secondary)
                if presentation.missingCoordinateCount > 0 {
                    Label("\(presentation.missingCoordinateCount) \(presentation.missingCoordinateCount == 1 ? "store has" : "stores have") no map location; shown below.", systemImage: "mappin.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(presentation.stores) { store in
                        InventoryMapStoreRow(store: store, selected: selectedStoreID == store.id) {
                            selectedStoreID = store.id
                            if let coordinate = store.coordinate {
                                camera = .region(MKCoordinateRegion(center: coordinate.mapCoordinate,
                                                                    span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)))
                            }
                        }
                    }
                    if presentation.stores.isEmpty {
                        ContentUnavailableView("No stores loaded", systemImage: "storefront", description: Text("Choose a country and enter your postal code or city above."))
                    }
                }.padding(12)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private var alertBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: notificationsEnabled ? "bell.badge.fill" : "bell.slash")
                .font(.title3).foregroundStyle(notificationsEnabled ? Color.accentColor : .secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(alertSummary).font(.callout.weight(.semibold))
                Text(notificationError ?? deliveryDetails).font(.caption).foregroundStyle(notificationError == nil ? Color.secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Enable alerts", systemImage: "bell", action: enableAlerts)
            if unreadCount > 0 {
                Button("Acknowledge \(unreadCount)", systemImage: "checkmark.circle", action: acknowledge)
                    .accessibilityLabel("Acknowledge \(unreadCount) inventory changes and clear the app badge")
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func fitNearbyStores() {
        let coordinates = cameraSeed.coordinates
        let points = coordinates.map { MKMapPoint($0.mapCoordinate) }
        guard let first = points.first else { camera = .automatic; return }
        let initial = MKMapRect(x: first.x, y: first.y, width: 0, height: 0)
        let bounds = points.dropFirst().reduce(initial) { $0.union(MKMapRect(x: $1.x, y: $1.y, width: 0, height: 0)) }
        let minimumPadding = MKMapPointsPerMeterAtLatitude(coordinates[0].latitude) * 1_500
        let padding = max(minimumPadding, max(bounds.width, bounds.height) * 0.15)
        camera = .rect(bounds.insetBy(dx: -padding, dy: -padding))
    }
}

private struct InventoryMapCameraSeed: Hashable {
    let location: String
    let coordinates: [Coordinate]
}

private extension Coordinate {
    var mapCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
