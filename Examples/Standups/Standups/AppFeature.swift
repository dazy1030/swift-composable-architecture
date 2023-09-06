import ComposableArchitecture
import SwiftUI

struct AppFeature: Reducer {
  @ObservableState
  struct State: Equatable {
    var path = StackState<Path.State>()
    var standupsList = StandupsList.State()
  }

  enum Action: Equatable {
    case path(StackAction<Path.State, Path.Action>)
    case standupsList(StandupsList.Action)
  }

  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.dataManager.save) var saveData
  @Dependency(\.uuid) var uuid

  private enum CancelID {
    case saveDebounce
  }

  var body: some ReducerOf<Self> {
    Scope(state: \.standupsList, action: /Action.standupsList) {
      StandupsList()
    }
    Reduce<State, Action> { state, action in
      switch action {
      case let .path(.element(id, .detail(.delegate(delegateAction)))):
        guard case let .some(.detail(detailState)) = state.path[id: id]
        else { return .none }

        switch delegateAction {
        case .deleteStandup:
          state.standupsList.standups.remove(id: detailState.standup.id)
          return .none

        case let .standupUpdated(standup):
          state.standupsList.standups[id: standup.id] = standup
          return .none

        case .startMeeting:
          state.path.append(.record(RecordMeeting.State(standup: detailState.standup)))
          return .none
        }

      case let .path(.element(_, .record(.delegate(delegateAction)))):
        switch delegateAction {
        case let .save(transcript: transcript):
          guard let id = state.path.ids.dropLast().last
          else {
            XCTFail(
              """
              Record meeting is the only element in the stack. A detail feature should precede it.
              """
            )
            return .none
          }

          state.path[id: id, case: /Path.State.detail]?.standup.meetings.insert(
            Meeting(
              id: Meeting.ID(self.uuid()),
              date: self.now,
              transcript: transcript
            ),
            at: 0
          )
          guard let standup = state.path[id: id, case: /Path.State.detail]?.standup
          else { return .none }
          state.standupsList.standups[id: standup.id] = standup
          return .none
        }

      case .path:
        return .none

      case .standupsList:
        return .none
      }
    }
    .forEach(\.path, action: /Action.path) {
      Path()
    }

    Reduce<State, Action> { state, action in
      return .run { [standups = state.standupsList.standups] _ in
        try await withTaskCancellation(id: CancelID.saveDebounce, cancelInFlight: true) {
          try await self.clock.sleep(for: .seconds(1))
          try await self.saveData(JSONEncoder().encode(standups), .standups)
        }
      } catch: { _, _ in
      }
    }
  }

  struct Path: Reducer {
    enum State: Equatable, ObservableState {
      case detail(StandupDetail.State)
      case meeting(Meeting, standup: Standup)
      case record(RecordMeeting.State)

      var _$id: StateID {
        switch self {
        case let .detail(detail):
          return detail._$id

        case .meeting:
          return StateID() // TODO: StateID.empty

        case let .record(record):
          return record._$id
        }
      }
    }

    enum Action: Equatable {
      case detail(StandupDetail.Action)
      case record(RecordMeeting.Action)
    }

    var body: some Reducer<State, Action> {
      Scope(state: /State.detail, action: /Action.detail) {
        StandupDetail()
      }
      Scope(state: /State.record, action: /Action.record) {
        RecordMeeting()
      }
    }
  }
}

struct AppView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    NavigationStackStore(store.scope(state: \.path, action: { .path($0) })) {
      StandupsListView(
        store: store.scope(state: \.standupsList, action: { .standupsList($0) })
      )
    } destination: {
      switch $0 {
      case .detail:
        CaseLet(
          /AppFeature.Path.State.detail,
          action: AppFeature.Path.Action.detail,
          then: StandupDetailView.init(store:)
        )
      case let .meeting(meeting, standup: standup):
        MeetingView(meeting: meeting, standup: standup)
      case .record:
        CaseLet(
          /AppFeature.Path.State.record,
          action: AppFeature.Path.Action.record,
          then: RecordMeetingView.init(store:)
        )
      }
    }
  }
}

extension URL {
  static let standups = Self.documentsDirectory.appending(component: "standups.json")
}
