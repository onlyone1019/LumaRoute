import SwiftUI
import LumaRouteCore

struct ProfileRow:View {
    @EnvironmentObject var store:AppStore
    @State private var showingOptions = false
    @State private var editingComposition = false
    @State private var showingChanges = false
    var profile:Profile
    private var active:Bool { store.database.activeProfileID == profile.id }
    private var badge:(icon:String,tint:Color) {
        profile.composition != nil ? ("square.stack.3d.up.fill",.indigo):profile.isRemote ? ("link",LumaPalette.accent):("doc.fill",.teal)
    }
    var body:some View {
        Panel(emphasized:active) {
            HStack(alignment:.center,spacing:16) {
                IconBadge(icon:badge.icon,tint:badge.tint)
                info.frame(maxWidth:.infinity,alignment:.leading)
                usage.frame(width:190,alignment:.leading)
                actions.frame(width:196,alignment:.trailing)
            }
        }
        .sheet(isPresented:$editingComposition) { CompositionSheet(profile:profile,profiles:store.database.profiles,activeID:store.database.activeProfileID) }
        .sheet(isPresented:$showingOptions) { SubscriptionOptionsSheet(profile:profile) }
        .sheet(isPresented:$showingChanges) { SubscriptionChangesSheet(profile:profile) }
    }
    private var info:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(spacing:8) {
                Text(profile.name).font(.system(size:15,weight:.semibold)).lineLimit(1)
                if active { StatusPill(text:"使用中") }
            }
            Text(profile.displaySource).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(1)
            Text((profile.lastUpdated.map { "上次更新 "+$0.formatted(date:.abbreviated,time:.shortened) } ?? "尚未更新")+(profile.isRemote ? " · 每 \(profile.updateHours.formatted()) 小时更新":"")).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(2)
            if profile.composition != nil { Text("组合配置 · 可按域名选择订阅").font(.system(size:12)).foregroundStyle(.secondary) }
            if profile.userAgent != nil { Label("自定义 User-Agent",systemImage:"slider.horizontal.3").font(.system(size:12)).foregroundStyle(.secondary) }
            if let error=profile.lastError { Label("更新失败，已保留旧配置："+error,systemImage:"exclamationmark.triangle.fill").font(.system(size:12)).foregroundStyle(.orange).lineLimit(2) }
            if let change = profile.lastChange {
                Button(change.summary+" · 查看变化") { showingChanges = true }.buttonStyle(.link).font(.system(size:12))
                if !change.selectedNodesRemoved.isEmpty { Label("原选中节点已移除，请检查当前出口",systemImage:"exclamationmark.triangle.fill").font(.system(size:12)).foregroundStyle(.orange) }
            }
        }
    }
    private var usage:some View {
        VStack(alignment:.leading,spacing:7) {
            if let composition = profile.composition {
                Text("参与订阅").font(.system(size:13,weight:.medium))
                Text(store.subscriptionProfiles.filter { composition.profileIDs.contains($0.id) }.map(\.name).joined(separator:"、")).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(2)
            } else if let used=profile.usage {
                Text("已用 "+Format.bytes(used.usedBytes)+(used.total.map { " / "+Format.bytes($0) } ?? "")).font(.system(size:13,weight:.medium)).monospacedDigit()
                if let fraction=used.usedFraction { UsageBar(fraction:fraction) }
                Text(used.expire.map { "到期 "+$0.formatted(date:.abbreviated,time:.omitted) } ?? "到期信息未提供").font(.system(size:12)).foregroundStyle(.secondary)
            } else { Text("流量信息未提供").font(.system(size:13)).foregroundStyle(.secondary) }
        }
    }
    private var actions:some View {
        HStack(spacing:8) {
            if profile.composition != nil { Button("编辑组合") { editingComposition = true } }
            if profile.isRemote { Button("更新") { store.perform { try await store.update(profile) } } }
            if !active { Button("启用") { store.perform { try await store.activate(profile) } }.buttonStyle(.borderedProminent) }
            Menu {
                if profile.isRemote { Button("订阅设置…") { showingOptions = true }; Divider() }
                Button("删除",role:.destructive) { store.perform { try await store.deleteProfile(profile) } }
            } label:{ Image(systemName:"ellipsis").frame(width:28,height:28).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("更多")
        }.fixedSize(horizontal:true,vertical:false).disabled(store.busy)
    }
}
