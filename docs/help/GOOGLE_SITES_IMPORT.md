# Importing the ScreenVoiceRec Help Page into Google Sites

This folder contains a bilingual (English / French) user guide for **ScreenVoiceRec**, aligned with the four numbered areas in the app screenshot.

## Files

| File | Purpose |
|------|---------|
| `index.html` | Full help page (open in any browser) |
| `assets/screenvoice-ui-screenshot.png` | Annotated UI screenshot |
| `GOOGLE_SITES_IMPORT.md` | This import guide |

---

## Option A — Embed the whole page (recommended)

Google Sites cannot upload a raw HTML file as a page, but you can host the page and embed it.

1. Sign in to [Google Drive](https://drive.google.com) with the same Google account you use for [Google Sites](https://sites.google.com/).
2. Upload the entire `docs/help` folder (keep `index.html` and `assets/` together).
3. Open `index.html` in Drive → **Share** → set to **Anyone with the link** (Viewer).
4. Use **File → Publish to the web** (or host on GitHub Pages / your own server) and copy the public URL of `index.html`.
5. In Google Sites: **Insert → Embed → Embed code**, paste:

   ```html
   <iframe src="YOUR_PUBLIC_URL/index.html" width="100%" height="3600" frameborder="0" style="border:0;"></iframe>
   ```

6. Adjust `height` so the full page scrolls inside the iframe, or use a tall value (e.g. 4000px) and preview.

**Tip:** If you use GitHub, push `docs/help/` and enable GitHub Pages for that folder; the embed URL will be stable.

---

## Option B — Rebuild the page inside Google Sites (copy/paste)

Use `index.html` as a reference and recreate content in the Sites editor.

1. Go to [Google Sites](https://sites.google.com/) → **Blank** site.
2. **Title:** `ScreenVoiceRec — User Guide / Guide d’utilisation`
3. **Insert → Image:** upload `assets/screenvoice-ui-screenshot.png`.
4. Add a **Text box** under the image with the legend:
   - 1 Source · 2 Export Format · 3 Controls · 4 Playback
5. For each section (Overview, 1–4, Save Location, Permissions, Quick Start):
   - **Insert → Layout → Two columns**
   - Left column: **English** heading + bullet list (copy from `index.html`)
   - Right column: **Français** heading + bullet list
6. Use **coloured labels** or numbered headings matching the screenshot (red 1, orange 2, green 3, purple 4).
7. **Publish** the site and share the link.

---

## Option C — Single long page from browser copy

1. Open `index.html` locally in Safari or Chrome (`docs/help/index.html`).
2. Select all (**⌘A**) → Copy (**⌘C**).
3. In Google Sites, **Insert → Text box** → Paste (**⌘V**).
4. Re-upload the screenshot separately (embedded images may not copy from HTML paste).
5. Fix formatting if needed (headings, lists).

---

## Suggested site structure (multi-page)

| Page | Content |
|------|---------|
| Home | Overview + screenshot + Quick Start (EN/FR columns) |
| 1. Source | Section 1 + permissions note for Screen Recording / Microphone |
| 2. Format | Section 2 + Save Location |
| 3. Recording | Section 3 (Controls) |
| 4. Playback | Section 4 + keyboard shortcuts |

Link pages from the home **Table of contents**.

---

## Preview locally

```bash
open docs/help/index.html
```

Ensure the screenshot appears next to `index.html` at `assets/screenvoice-ui-screenshot.png`.

---

## 图片无法显示（Drive 链接粘贴到 src 后仍空白）

这是**常见问题**：Google 云端硬盘的分享链接**不能**直接当作网页里的图片地址用。

### 先自检：你粘贴的是哪种链接？

| 链接样子 | 能否用于 `<img src>` |
|----------|----------------------|
| `https://drive.google.com/file/d/xxx/view?usp=sharing` | ❌ 不行（只是预览页） |
| `https://drive.google.com/uc?export=view&id=xxx` | ⚠️ 浏览器新标签有时能开，**Sites / 嵌入 HTML 里常被拦截** |
| `https://lh3.googleusercontent.com/...` | ✅ 可靠（来自 Google Sites 上传后的「复制图片地址」） |

**测试方法：** 把 `src` 里的地址复制到浏览器新标签打开。  
- 若出现 Google 登录页或文件列表 → 权限或链接格式不对  
- 若只有 `<img>` 里不显示、新标签能看 → 说明被 **Google Sites 禁止引用 Drive**，需改用下面方案 A  

### 方案 A — 在 Google Sites 上传（最推荐）

1. **不要**把 Drive 链接写进 HTML  
2. Sites 编辑器：**插入 → 图片 → 上传** 本地截图  
3. 发布或预览后，**右键图片 → 复制图片地址**（必须是 `lh3.googleusercontent.com` 开头）  
4. 再 **插入 → 嵌入 → 嵌入代码**，把该地址填入 `src=""`  

或者更简单：**截图用 Sites 自带「插入图片」**，文字说明用文本框，**不必写 HTML 包图片**。

### 方案 B — 本地预览 index.html

用 Drive 链接时，请用 **Safari/Chrome 直接打开** `index.html`（`file://` 或本地服务器），且 `src` 仍可能因 Drive 防盗链失败。  
本地最稳：保持相对路径  

```html
src="assets/screenvoice-ui-screenshot.png"
```

（`index.html` 与 `assets/` 文件夹必须在同一目录结构下。）

### 方案 C — GitHub Pages 托管整页

把 `docs/help/` 推到 GitHub 并开启 Pages 后，图片用相对路径即可，无需 Drive：

```html
src="assets/screenvoice-ui-screenshot.png"
```

整页 iframe 嵌入 Google Sites 时，图片会随页面一起正常显示。

