import SwiftUI

/// 自绘的左滑删除行：删除背景与卡片同高、同圆角，颜色固定为红色。
/// 卡片与删除区共用一个圆角裁剪，滑开时不会露出直角。
///
/// 关键点（保证列表行里既没有红色残影、又能正常删除）：
/// - 删除红底挂在 ZStack 的 `background(alignment: .trailing)` 上：尺寸严格等于卡片
///   （不会像兄弟节点那样在 List 行里被撑高撑宽），且位于卡片**下方**，滑动时逐段露出；
/// - 红底与「点红色区域 = 删除」的透明点击层都**只在滑动 / 展开时渲染**，静止时完全不绘制，
///   因此卡片上不会出现任何红色残影；
/// - 透明点击层挂在最上层：展开后卡片虽然视觉上滑走了，但它的布局仍覆盖整行，
///   只有最上层的点击层能稳定接住这一区域的点击。
///
/// 技能库、SSH 云服务器、MCP 服务器列表共用这一套左滑逻辑：
/// - 卡片本体不是 Button（否则会和左滑抢手势），点击与滑动都挂在内容上；
/// - 另外提供长按菜单兜底（个别机型手势不跟手时也能删除）。
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    /// 点击卡片（未滑开时）：进入编辑页 / 详情页等
    let onTap: () -> Void
    /// 长按菜单里「打开」一项的文字
    var tapTitle: String = "打开"
    /// 长按菜单里「删除」一项的文字
    var deleteTitle: String = "删除"
    @ViewBuilder var content: Content

    /// 删除按钮展开宽度
    private let actionWidth: CGFloat = 84

    @State private var offset: CGFloat = 0
    @State private var opened = false

    /// 是否已滑开（只要滑开一点就要绘制删除层）
    private var revealing: Bool { offset < 0 || opened }

    var body: some View {
        ZStack(alignment: .trailing) {
            content
                .offset(x: offset)
                // 滑动与点击都挂在卡片本体上：卡片不是 Button，两者不会互相抢手势
                .contentShape(Rectangle())
                .gesture(drag)
                .onTapGesture {
                    if opened {
                        close()
                    } else {
                        onTap()
                    }
                }
                // 长按兜底：万一滑动手势在个别机型上不跟手，也能从这里删除
                .contextMenu {
                    Button {
                        onTap()
                    } label: {
                        Label(tapTitle, systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        delete()
                    } label: {
                        Label(deleteTitle, systemImage: "trash")
                    }
                }
        }
        // 横向撑满所在行，卡片宽度与同页其它分组保持一致
        .frame(maxWidth: .infinity)
        .background(alignment: .trailing) {
            if revealing {
                Button {
                    delete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: actionWidth)
                        .frame(maxHeight: .infinity)
                        .background(DSHTheme.dangerSolid)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(deleteTitle)
            }
        }
        // 展开后在删除区上压一层透明点击层（最上层）：点红色区域就等于删除
        .overlay(alignment: .trailing) {
            if opened {
                Color.clear
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { delete() }
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.row, style: .continuous))
    }

    /// 删除这条记录：立即移除，不做多余动画
    private func delete() {
        opened = false
        offset = 0
        onDelete()
    }

    private func close() {
        withAnimation(DSHAnim.list) {
            opened = false
            offset = 0
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 纵向滑动交给外层滚动，避免抢手势
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base = opened ? -actionWidth : 0
                offset = min(0, max(-actionWidth, base + value.translation.width))
            }
            .onEnded { value in
                let dx = value.translation.width
                let projected = value.predictedEndTranslation.width
                // 横向位移明显、或「快速轻扫」都算想滑开：
                // 阈值放宽到 1/4 屏宽并使用惯性预测，避免手指刚滑开一点就弹回去
                let isHorizontal = abs(dx) > abs(value.translation.height)
                let isFlick = abs(projected) > actionWidth
                guard isHorizontal || isFlick else { return }
                let shouldOpen = opened
                    ? !(dx > actionWidth * 0.25 || projected > actionWidth * 0.5)
                    : (dx < -actionWidth * 0.25 || projected < -actionWidth * 0.5)
                withAnimation(DSHAnim.list) {
                    opened = shouldOpen
                    offset = shouldOpen ? -actionWidth : 0
                }
            }
    }
}