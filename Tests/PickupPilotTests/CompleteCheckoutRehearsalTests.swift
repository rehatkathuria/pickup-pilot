import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

private actor CompleteRehearsalMemoryVault: SecureVault {
    private var session: Data?
    private var profileWrites = 0
    private var orderWrites = 0
    func saveProfile(_ profile: SecureProfile) { profileWrites += 1 }
    func loadProfile() -> SecureProfile? { nil }
    func deleteProfile() {}
    func saveSession(_ data: Data) { session = data }
    func loadSession() -> Data? { session }
    func deleteSession() { session = nil }
    func saveOrderState(_ data: Data) { orderWrites += 1 }
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() { session = nil }
    func sensitiveWriteCounts() -> (profile: Int, order: Int) { (profileWrites, orderWrites) }
}

@MainActor private final class CompleteRehearsalTiming {
    private(set) var artificialWaits = 0
    func legacyPause() async throws {
        artificialWaits += 1
        try await AppleCheckoutTiming.pause()
    }
}

private struct CompleteCheckoutBenchmarkSample: Codable {
    let milliseconds: Double
    let artificialWaits: Int
    let eventWaits: Int
    let snapshots: Int
    let phases: Int
    let addedItems: Int
    let finalSubmissions: Int
}
private struct CompleteCheckoutBenchmarkReport: Codable {
    let scope: String
    let iterations: Int
    let baseline: [CompleteCheckoutBenchmarkSample]
    let eventDriven: [CompleteCheckoutBenchmarkSample]
    var baselineMedianMilliseconds: Double { baseline.map(\.milliseconds).sorted()[iterations/2] }
    var eventMedianMilliseconds: Double { eventDriven.map(\.milliseconds).sorted()[iterations/2] }
    func json() throws -> Data {
        var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(self)) as! [String:Any]
        value["baselineMedianMilliseconds"]=baselineMedianMilliseconds
        value["eventMedianMilliseconds"]=eventMedianMilliseconds
        value["speedup"]=baselineMedianMilliseconds/eventMedianMilliseconds
        value["baselineRangeMilliseconds"]=[baseline.map(\.milliseconds).min()!,baseline.map(\.milliseconds).max()!]
        value["eventRangeMilliseconds"]=[eventDriven.map(\.milliseconds).min()!,eventDriven.map(\.milliseconds).max()!]
        return try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
    }
}

/// The only replacement is navigation to local HTML. Every snapshot and advance is the
/// production WebKit bridge reading/changing the actual synthetic document.
@MainActor private final class CompleteRehearsalPage: AppleCheckoutPage {
    let native = WKAppleCheckoutPage(submissionAllowed: false)
    let request: CheckoutRequest
    let fixture: [String: Any]
    private(set) var loads: [URL] = []
    private(set) var observedPhases: [CheckoutSnapshot.Phase] = []
    private(set) var finalCalls = 0
    private(set) var eventWaits = 0

    init(request: CheckoutRequest, fixture: [String: Any]) {
        self.request = request
        self.fixture = fixture
        native.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
    }

    func load(_ url: URL) async throws {
        let initialStage: String
        if url.absoluteString == "https://www.apple.com/ca/shop/bag" { initialStage = "emptyBag" }
        else if url == request.variant.productURL { initialStage = "product" }
        else { throw CheckoutError.unsupportedPage }
        loads.append(url)
        let marker = UUID().uuidString
        var configuration = fixture
        configuration["marker"] = marker
        configuration["initialStage"] = initialStage
        let json = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)
        native.webView.loadHTMLString(Self.document(configurationJSON: json), baseURL: url)
        for _ in 0..<150 {
            let current = try? await evaluate("return document.documentElement.dataset.completeFixture || ''; ")
            if current as? String == marker, !native.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckoutError.unsupportedPage
    }
    func snapshot() async throws -> CheckoutSnapshot {
        let result = try await native.snapshot()
        observedPhases.append(result.phase)
        return result
    }
    func advance(request: CheckoutRequest, profile: SecureProfile) async throws -> Bool {
        try await native.advance(request: request, profile: profile)
    }
    func continueAsGuest(request: CheckoutRequest, snapshot: CheckoutSnapshot) async throws -> Bool {
        try await native.continueAsGuest(request: request, snapshot: snapshot)
    }
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) async throws -> Bool {
        eventWaits += 1
        return try await native.waitForChange(after:snapshot,timeout:timeout)
    }
    func acknowledgeManualInput(market: Market) async throws { try await native.acknowledgeManualInput(market:market) }
    func placeOrder(expected: CheckoutSnapshot) async throws -> Bool {
        finalCalls += 1
        return try await native.placeOrder(expected: expected)
    }
    func restoreSession(_ data: Data?) async throws { try await native.restoreSession(data) }
    func sessionData() async throws -> Data { try await native.sessionData() }
    func cancel() { native.cancel() }
    func clearPage() { native.clearPage() }
    func evaluate(_ script: String) async throws -> Any? {
        try await native.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }

    private static func document(configurationJSON: String) -> String {
        #"""
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; form-action 'none'; connect-src 'none'; frame-src 'none'">
        <style>body{font:16px system-ui}input,select,button{display:block;margin:8px;min-height:24px}</style>
        </head><body>
        <script id="metrics" type="application/json">{"data":{"properties":{"currencyCode":"CAD"}}}</script>
        <script id="init_data" type="application/json">{}</script><main id="stage"></main>
        <script>
        (()=>{
          const configuration=
        \#(configurationJSON)
          ;
          const state={stage:'',history:[],adds:0,noTradeIn:0,noAppleCare:0,bagCheckouts:0,
            guestContinuations:0,contactFieldsFilled:false,paymentFieldsFilled:false,pickupSelectionValid:false,
            selectedStore:null,selectedDay:null,selectedSlot:null,finalClicks:0,finalSubmissions:0};
          const container=document.getElementById('stage'),model=document.getElementById('init_data');
          const input=(name,extra='')=>`<input data-autom="form-field-${name}" ${extra}>`;
          const field=name=>document.querySelector(`[data-autom="form-field-${name}"]`)?.value||'';
          const move=(stage,data,html)=>{
            state.stage=stage;state.history.push(stage);model.textContent=JSON.stringify(data);
            container.innerHTML=html;
            const path=stage==='product'?configuration.productPath:
              ['emptyBag','bag'].includes(stage)?'/ca/shop/bag':stage==='authentication'?'/ca/shop/signIn':'/ca/shop/checkout';
            history.replaceState(null,'',path);
          };
          const render=stage=>{
            if(stage==='emptyBag')return move(stage,{shoppingCart:{d:{hasItems:false},items:{}}},'<p>Synthetic empty bag</p>');
            if(stage==='product')return move(stage,{},`
              <form data-part-number="${configuration.sku}" onsubmit="event.preventDefault()">
                <input type="radio" data-autom="choose-noTradeIn" onclick="__completeFixture.state.noTradeIn++">
                <input type="radio" data-autom="noapplecare" onclick="__completeFixture.state.noAppleCare++">
                <input type="radio" data-autom="purchaseOptionFullPrice" checked>
                <input type="radio" data-autom="unlocked" checked>
                <button type="button" data-autom="add-to-cart" onclick="__completeFixture.add()">Synthetic Add to Bag</button>
              </form>`);
            if(stage==='bag')return move(stage,{shoppingCart:{d:{hasItems:true},items:{phone:{d:{productId:configuration.sku,quantity:state.adds}}}}},
              '<button type="button" data-autom="bag-checkout-button" onclick="__completeFixture.checkout()">Synthetic Checkout</button>');
            if(stage==='authentication')return move(stage,{},`
              <input type="password" autocomplete="current-password" aria-label="Synthetic password">
              <button type="button" data-autom="guest-checkout-btn" onclick="__completeFixture.continueAsGuest()">Continue as Guest</button>`);
            if(stage==='fulfillment'){
              const timeSlot={d:{pickUpDates:configuration.days,timeSlotWindows:configuration.windows}};
              return move(stage,{checkout:{fulfillment:{pickupTab:{pickup:{timeSlot}}}}},`
                <input type="radio" name="fulfillment" value="PICKUP">
                <input type="radio" name="store-locator-result" value="R999">
                <input type="radio" name="store-locator-result" value="${configuration.storeID}">
                ${configuration.days.map(day=>`<input type="radio" name="bartPickupDateSelectorButtonGroup" value="${day.dayOfMonth}">`).join('')}
                <select data-autom="pickup-availablewindow-dropdown"><option value="">Choose a synthetic slot</option>
                  ${configuration.slots.map(slot=>`<option value="${slot.timeSlotValue}">${slot.label}</option>`).join('')}
                </select>
                <button type="button" data-autom="fulfillment-continue-button" onclick="__completeFixture.continuePickup()">Synthetic Pickup Continue</button>`);
            }
            if(stage==='contact')return move(stage,{checkout:{contact:{}}},`
              <section class="rs-pickup-contact-details">
                ${['firstName','lastName','emailAddress','mobilePhone'].map(name=>input(name)).join('')}
                <button type="button" data-autom="continue-button-label" onclick="__completeFixture.continueContact()">Synthetic Contact Continue</button>
              </section>`);
            if(stage==='payment')return move(stage,{checkout:{billing:{}}},`
              ${['cardholder','street','street2','city','postalCode'].map(name=>input(name)).join('')}
              <select data-autom="form-field-province"><option value="">Province</option><option value="ON">Ontario</option></select>
              <select data-autom="form-field-country"><option value="">Country</option><option value="CA">Canada</option></select>
              <input data-autom="card-number-input"><input data-autom="expiration-input"><input data-autom="security-code-input">
              <button type="button" data-autom="continue-button-review" onclick="__completeFixture.continuePayment()">Synthetic Review</button>`);
            if(stage==='review'){
              const chosen=configuration.slots.find(slot=>slot.timeSlotValue===state.selectedSlot);
              const pickup={storeNumber:state.selectedStore,startTime:chosen.startISO,endTime:chosen.endISO,timeslot:chosen.label};
              const group={d:{pickup},items:{phone:{d:{productId:configuration.sku,quantity:state.adds}}}};
              return move(stage,{checkout:{review:{billingReview:{d:{paymentLabel:'Synthetic Payment A'}},fulfillmentReview:{group}}}},`
                <section class="rs-review-billing"><p class="rs-review-cardnumber">Synthetic Payment A</p></section>
                <span data-autom="orderTotalValue">CA$3,388.87</span>
                <form id="synthetic-final-order" onsubmit="event.preventDefault();__completeFixture.state.finalSubmissions++">
                  <button type="submit" data-autom="continue-button-placeOrder" onclick="__completeFixture.state.finalClicks++">Synthetic Place Order</button>
                </form>`);
            }
          };
          const fixture={state,
            add(){state.adds++;render('bag');},
            checkout(){state.bagCheckouts++;render('authentication');},
            continueAsGuest(){state.guestContinuations++;render('fulfillment');},
            continuePickup(){
              state.selectedStore=document.querySelector('input[name="store-locator-result"]:checked')?.value||null;
              state.selectedDay=document.querySelector('input[name="bartPickupDateSelectorButtonGroup"]:checked')?.value||null;
              state.selectedSlot=document.querySelector('[data-autom="pickup-availablewindow-dropdown"]').value;
              const selected=configuration.slots.find(slot=>slot.timeSlotValue===state.selectedSlot);
              state.pickupSelectionValid=!!document.querySelector('input[value="PICKUP"]:checked')&&
                state.selectedStore===configuration.storeID&&selected?.day===state.selectedDay;
              if(state.pickupSelectionValid)render('contact');
            },
            continueContact(){
              state.contactFieldsFilled=field('firstName')==='Synthetic'&&field('lastName')==='Tester'&&
                field('emailAddress')==='synthetic@example.invalid'&&field('mobilePhone')==='+14165550100';
              if(state.contactFieldsFilled)render('payment');
            },
            continuePayment(){
              state.paymentFieldsFilled=field('cardholder')==='Synthetic Tester'&&field('street')==='1 Synthetic Street'&&
                field('street2')==='Synthetic Unit'&&field('city')==='Toronto'&&field('province')==='ON'&&
                field('postalCode')==='M5V 3L9'&&field('country')==='CA'&&
                document.querySelector('[data-autom="card-number-input"]').value==='4111111111111111'&&
                document.querySelector('[data-autom="expiration-input"]').value==='12/99'&&
                document.querySelector('[data-autom="security-code-input"]').value==='123';
              if(state.paymentFieldsFilled)render('review');
            }
          };
          Object.defineProperty(window,'__completeFixture',{value:fixture,writable:false,configurable:false});
          render(configuration.initialStage);
          document.documentElement.dataset.completeFixture=configuration.marker;
        })();
        </script></body></html>
        """#
    }
}

/// Synthetic integration evidence only. This does not establish Apple account, stock,
/// payment acceptance or final-review compatibility on the live Apple storefront.
@Suite(.serialized) @MainActor struct CompleteCheckoutRehearsalTests {
    @Test func productionBrowserDriverAndRehearsalTraverseEveryPreorderStageWithoutOrdering() async throws {
        let result=try await completeFlow(legacyFixedWait:false)
        #expect(result.artificialWaits == 0 && result.eventWaits > 0)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["PICKUP_PILOT_CHECKOUT_BENCHMARK"] == "1"))
    func productionCheckoutTimingBenchmark() async throws {
        var baseline:[CompleteCheckoutBenchmarkSample]=[],eventDriven:[CompleteCheckoutBenchmarkSample]=[]
        for _ in 0..<3 {
            baseline.append(try await completeFlow(legacyFixedWait:true))
            eventDriven.append(try await completeFlow(legacyFixedWait:false))
        }
        #expect(baseline.allSatisfy({$0.artificialWaits > 0 && $0.eventWaits == 0}))
        #expect(eventDriven.allSatisfy({$0.artificialWaits == 0 && $0.eventWaits > 0}))
        let report=CompleteCheckoutBenchmarkReport(
            scope:"Local synthetic Apple-origin WebKit only; same current driver and validation, injected legacy 600ms waits versus native event waits; automatic guest continuation and simulated immediate payment confirmation; no network or orders.",
            iterations:3,baseline:baseline,eventDriven:eventDriven)
        let location=ProcessInfo.processInfo.environment["PICKUP_PILOT_CHECKOUT_BENCHMARK_PATH"] ?? "work/checkout-performance.json"
        let destination=URL(fileURLWithPath:location)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        try report.json().write(to:destination,options:.atomic)
        print("Synthetic checkout benchmark: fixed-wait median \(report.baselineMedianMilliseconds)ms; event median \(report.eventMedianMilliseconds)ms; 3 iterations each; final submissions zero.")
    }
    private func completeFlow(legacyFixedWait:Bool) async throws -> CompleteCheckoutBenchmarkSample {
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let firstDay=calendar.date(byAdding:.day,value:7,to:calendar.startOfDay(for:Date()))!
        let laterDay=calendar.date(byAdding:.day,value:1,to:firstDay)!
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=calendar.timeZone;formatter.dateFormat="yyyy-MM-dd"
        let iso=ISO8601DateFormatter()
        func slot(_ value:String,day:Date,start:Int,end:Int,enabled:Bool=true,restricted:Bool=false)->[String:Any] {
            let beginning=day.addingTimeInterval(TimeInterval(start*60)),ending=day.addingTimeInterval(TimeInterval(end*60))
            return ["timeSlotValue":value,"day":String(calendar.component(.day,from:day)),
                    "checkInStart":String(format:"%02d:%02d",start/60,start%60),"checkInEnd":String(format:"%02d:%02d",end/60,end%60),
                    "timeZone":"UTC","enabled":enabled,"isRestricted":restricted,
                    "startISO":iso.string(from:beginning),"endISO":iso.string(from:ending),"label":"Synthetic \(value)"]
        }
        let earliest=slot("earliest-permitted",day:firstDay,start:600,end:615)
        let later=slot("later-permitted",day:firstDay,start:645,end:660)
        let restricted=slot("restricted",day:firstDay,start:600,end:615,restricted:true)
        let disabled=slot("disabled",day:firstDay,start:600,end:615,enabled:false)
        let outside=slot("outside-hours",day:firstDay,start:540,end:555)
        let followingDay=slot("following-day",day:laterDay,start:600,end:615)
        let firstNumber=String(calendar.component(.day,from:firstDay)),laterNumber=String(calendar.component(.day,from:laterDay))
        let request=CheckoutRequest(variant:ProductVariant(id:"COMPLETE-SYNTHETIC-CA/A",name:"Synthetic Duo",storage:"256GB",color:"Night Sky",
                                                          productURL:URL(string:"https://www.apple.com/ca/shop/buy-iphone/iphone-duo/complete-synthetic")!),
                                    store:RetailStore(id:"R121",name:"Synthetic Eaton Centre",countryCode:"CA"),market:.ca,maximumTotal:4_000,
                                    pickupWindow:DateWindow(start:firstDay,end:laterDay.addingTimeInterval(86_399)),
                                    pickupHours:DailyWindow(startMinute:600,endMinute:660),timeZoneIdentifier:"UTC")
        let configuration:[String:Any]=[
            "sku":request.variant.id,"storeID":request.store.id,"productPath":request.variant.productURL.path,
            "days":[["dayOfMonth":laterNumber,"date":formatter.string(from:laterDay)],["dayOfMonth":firstNumber,"date":formatter.string(from:firstDay)]],
            "windows":[[laterNumber:[followingDay],firstNumber:[later,restricted,disabled,outside,earliest]]],
            "slots":[followingDay,later,restricted,disabled,outside,earliest]
        ]
        let page=CompleteRehearsalPage(request:request,fixture:configuration)
        let vault=CompleteRehearsalMemoryVault()
        let timing=CompleteRehearsalTiming()
        let driver: AppleCheckoutDriver
        if legacyFixedWait {
            driver=AppleCheckoutDriver(vault:vault,page:page,webView:page.native.webView,sleep:timing.legacyPause)
        } else {
            driver=AppleCheckoutDriver(vault:vault,page:page,webView:page.native.webView)
        }
        let rehearsal=CheckoutRehearsal(driver:driver,webView:page.native.webView)
        defer { rehearsal.cancel();page.clearPage() }
        let profile=SecureProfile(givenName:"Synthetic",familyName:"Tester",email:"synthetic@example.invalid",phone:"+14165550100",
                                  cardholder:"Synthetic Tester",cardNumber:"4111111111111111",expiryMonth:"12",expiryYear:"2099",cvv:"123",
                                  billingLine1:"1 Synthetic Street",billingLine2:"Synthetic Unit",billingCity:"Toronto",billingRegion:"ON",
                                  billingPostalCode:"M5V 3L9",billingCountry:"CA",searchLocation:"M5V 3L9")

        let started=ContinuousClock.now
        await rehearsal.start(request:request,profile:profile)
        #expect(rehearsal.state == .manualInputRequired && rehearsal.review == nil)
        #expect(page.loads.map(\.path) == ["/ca/shop/bag",request.variant.productURL.path])
        #expect(try await page.evaluate("return __completeFixture.state.adds;") as? Int == 1)
        #expect(page.finalCalls == 0)
        #expect(try await page.native.snapshot().phase == .review)
        #expect(page.finalCalls == 0)
        // Automatic guest continuation and field entry are not payment approval. The human
        // separately inspects the final payment method and continues this exact review.
        await rehearsal.resume()
        #expect(rehearsal.state == .reviewReady)
        let elapsed=started.duration(to:.now).components
        let milliseconds=Double(elapsed.seconds)*1_000+Double(elapsed.attoseconds)/1_000_000_000_000_000
        let review=try #require(rehearsal.review)
        try review.validate(for:request,at:Date())
        #expect(review.variantID == request.variant.id && review.storeID == request.store.id && review.quantity == 1)
        #expect(review.total == Decimal(string:"3388.87") && review.currencyCode == "CAD")
        #expect(review.pickupDate == firstDay.addingTimeInterval(600*60) && review.pickupEndDate == firstDay.addingTimeInterval(615*60))
        #expect(review.pickupSlot == "Synthetic earliest-permitted")
        #expect(review.sourceURL == "https://www.apple.com/ca/shop/checkout")
        #expect(rehearsal.webView === page.native.webView)
        for phase in [CheckoutSnapshot.Phase.bag,.product,.authentication,.fulfillment,.contact,.payment,.review] {
            #expect(page.observedPhases.contains(phase))
        }
        let state=try #require(try await page.evaluate("return {...__completeFixture.state};") as? [String:Any])
        for key in ["adds","noTradeIn","noAppleCare","bagCheckouts","guestContinuations"] { #expect(state[key] as? Int == 1) }
        for key in ["pickupSelectionValid","contactFieldsFilled","paymentFieldsFilled"] { #expect(state[key] as? Bool == true) }
        #expect(state["selectedStore"] as? String == request.store.id && state["selectedDay"] as? String == firstNumber)
        #expect(state["selectedSlot"] as? String == "earliest-permitted")
        #expect(state["history"] as? [String] == ["product","bag","authentication","fulfillment","contact","payment","review"])
        let writes=await vault.sensitiveWriteCounts()
        #expect(writes.profile == 0 && writes.order == 0 && page.finalCalls == 0)

        let snapshot=try await page.native.snapshot()
        #expect(try await page.native.placeOrder(expected:snapshot,request:request,review:review) == false)
        _ = try await page.evaluate("document.querySelector('[data-autom=continue-button-placeOrder]').click();return true;")
        #expect(try await page.evaluate("return __completeFixture.state.finalClicks;") as? Int == 0)
        #expect(try await page.evaluate("return __completeFixture.state.finalSubmissions;") as? Int == 0)
        #expect(try await page.evaluate("return window.__pickupPilotReviewOnly===true;") as? Bool == true)
        await rehearsal.resume()
        #expect(rehearsal.review == review && page.loads.count == 2 && page.finalCalls == 0)
        #expect(try await page.evaluate("return __completeFixture.state.adds;") as? Int == 1)
        return CompleteCheckoutBenchmarkSample(milliseconds:milliseconds,artificialWaits:timing.artificialWaits,eventWaits:page.eventWaits,
                                               snapshots:page.observedPhases.count,phases:(state["history"] as? [String])?.count ?? 0,
                                               addedItems:state["adds"] as? Int ?? -1,finalSubmissions:state["finalSubmissions"] as? Int ?? -1)
    }
}
