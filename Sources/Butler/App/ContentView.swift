import SwiftUI

struct ContentView: View {
    @ObservedObject var model: Model
    @ObservedObject private var tasks = Tasks.shared

    var body: some View {
        ZStack(alignment: .top) {
            switch model.tab {
            case .storage: StorageView(model: model)
            case .tasks: TasksView(tasks: tasks)
            case .activity: ActivityView(monitor: .shared)
            }
            Picker("", selection: $model.tab) {
                Text("Storage").tag(Model.Tab.storage)
                Text(tasks.open.isEmpty ? "Tasks" : "Tasks · \(tasks.open.count)").tag(Model.Tab.tasks)
                Text("Activity").tag(Model.Tab.activity)
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(width: 290)
            .padding(.top, 10)
        }
        .frame(minWidth: 700, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if model.spots.isEmpty { model.scan() } }
    }
}
