import SwiftUI

enum LumaControl {
    static let height: CGFloat = 32
    static let cornerRadius: CGFloat = 7
}

struct LumaTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).focused($focused)
            .font(.system(size:13))
            .padding(.horizontal,10)
            .frame(height:LumaControl.height)
            .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:LumaControl.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius:LumaControl.cornerRadius).stroke(focused ? LumaPalette.accent:Color.primary.opacity(0.16),lineWidth:focused ? 2:1))
            .opacity(enabled ? 1:0.45)
    }
}

struct LumaButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        LumaButtonLabel(configuration:configuration,prominent:prominent)
    }
}

struct LumaButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size:13,weight:prominent ? .medium:.regular))
            .lineLimit(1)
            .padding(.horizontal,12)
            .frame(minHeight:LumaControl.height)
            .foregroundStyle(prominent ? Color.white:configuration.role == .destructive ? .red:.primary)
            .background(prominent ? LumaPalette.accent:Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:LumaControl.cornerRadius))
            .overlay {
                if !prominent { RoundedRectangle(cornerRadius:LumaControl.cornerRadius).stroke(Color.primary.opacity(0.16),lineWidth:1) }
            }
            .contentShape(RoundedRectangle(cornerRadius:LumaControl.cornerRadius))
            .opacity(!enabled ? 0.45:configuration.isPressed ? 0.7:1)
    }
}

/// Keep a bounded, readable label while AppKit presents the actual menu.
struct LumaMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing:8) {
                Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth:.infinity,alignment:.leading)
                Image(systemName:"chevron.down").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .font(.system(size:13))
            .foregroundStyle(.primary)
            .padding(.horizontal,10)
            .frame(height:LumaControl.height)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:LumaControl.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius:LumaControl.cornerRadius).stroke(Color.primary.opacity(0.16),lineWidth:1))
            .contentShape(RoundedRectangle(cornerRadius:LumaControl.cornerRadius))
            .opacity(enabled ? 1:0.45)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal:false,vertical:true)
    }
}

/// The inline Picker retains native selection checkmarks and keyboard navigation.
struct LumaPicker<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    let value: String
    var showsLabel = false
    @ViewBuilder var content: Options

    init(_ title: String,selection: Binding<Selection>,value: String,showsLabel: Bool = false,@ViewBuilder content: () -> Options) {
        self.title = title; _selection = selection; self.value = value; self.showsLabel = showsLabel; self.content = content()
    }

    var body: some View {
        if showsLabel {
            HStack(spacing:12) {
                Text(title).frame(width:88,alignment:.leading)
                menu
            }
        } else {
            menu
        }
    }

    private var menu: some View {
        LumaMenu(title:value) {
            Picker(title,selection:$selection) { content }.pickerStyle(.inline).labelsHidden()
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .help(value)
    }
}

struct RuleOrderButtons: View {
    var canMoveUp: Bool
    var canMoveDown: Bool
    var moveUp: () -> Void
    var moveDown: () -> Void

    var body: some View {
        HStack(spacing:2) {
            Button(action:moveUp) { Image(systemName:"chevron.up").frame(width:26,height:LumaControl.height) }
                .disabled(!canMoveUp).help("上移规则").accessibilityLabel("上移规则")
            Button(action:moveDown) { Image(systemName:"chevron.down").frame(width:26,height:LumaControl.height) }
                .disabled(!canMoveDown).help("下移规则").accessibilityLabel("下移规则")
        }.buttonStyle(.borderless)
    }
}
