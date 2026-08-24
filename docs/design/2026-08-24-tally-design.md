# tally.nvim 設計

- 日付: 2026-08-24
- ステータス: 設計確定・実装前

## 1. 目的

インストール済み Neovim プラグインの棚卸しを、記憶や印象ではなく実測に基づいて行えるようにする。

日常的にプラグインの使用を記録し続け、`:Tally` で「一度もロードされていない」「数ヶ月使っていない」プラグインを提示する。判断材料の提供までが責務であり、削除そのものは行わない。

## 2. スコープ

### やること

- プラグインのロード、Ex コマンド実行、keymap 発火の3種類を記録する
- 記録をローカルに永続化し、複数セッション・複数 Neovim インスタンスをまたいで集計する
- 全プラグインを使用頻度順に並べたレポートを表示する

### やらないこと

- **Lua モジュール関数の呼び出し追跡**。telescope 等の `__index` 遅延ロードや metatable で壊れやすく、ローカル変数に束縛された関数参照は捕捉できない。加えて測れるのは「プラグイン同士の依存」であって利用者の使用ではない
- **表示・常駐系プラグインの有用性の計測**。colorscheme や hlchunk が「役に立ったか」は原理的に計測不能。`passive` タグによる判定除外で対応する（後述）
- **プラグインの自動削除・無効化**
- **外部への送信**。記録は完全にローカルに閉じる
- **lazy.nvim 以外のプラグインマネージャ対応**。帰属解決の主軸が lazy の spec 情報である以上、対応しても精度が出ない

## 3. 前提

- Neovim >= 0.10（`vim.uv`、`vim.json` を使う）
- lazy.nvim 必須

## 4. 用語

| 語 | 意味 |
|---|---|
| 帰属 (attribution) | 観測したイベントをどのプラグインの使用として数えるかの決定 |
| シグナル | 使用を示す観測可能な事象。`load` / `cmd` / `key` の3種 |
| passive | 呼び出されないが価値のあるプラグイン。利用者が手で指定し、未使用判定から除外する |

## 5. アーキテクチャ

```
             ┌───────────┐
  イベント発生 →│  track    │ 計測: LazyLoad / CmdlineLeave / keymap ラップ
             └─────┬─────┘
                   │ (plugin, kind, name)
             ┌─────▼─────┐
             │  attrib   │ 帰属解決: lazy spec → LazyLoad 差分 → source path
             └─────┬─────┘
                   │
             ┌─────▼─────┐
             │   init    │ メモリ上に差分カウンタを保持、定期 flush
             └─────┬─────┘
                   │
             ┌─────▼─────┐
             │   store   │ JSONL 追記 / 読み出し
             └─────┬─────┘
                   │
             ┌─────▼─────┐
             │  report   │ 集計 + 描画 (:Tally)
             └───────────┘
```

各モジュールは単方向に依存する。`report` は `store` のみに依存し、計測系を一切参照しない。

## 6. 帰属解決 (`attrib.lua`)

イベントをプラグインに紐付ける。精度の高い順に3段階。

### 6.1 lazy spec からのインデックス（最優先・正確）

`require("lazy").plugins()` が返す各 spec の `keys` / `cmd` フィールドは、lhs およびコマンド名とプラグインの対応を宣言的に持っている。計測なしで正確な対応表が得られる。

```
by_key[mode][lhs] = plugin_name
by_cmd[cmd_name]  = plugin_name
```

`keys` の要素は文字列または `{ lhs, rhs, mode = ... }` 形式のテーブル。`mode` の既定は `"n"`、リストで複数指定されうる。`cmd` は文字列または文字列配列。

このインデックスは起動時ではなく**最初の `LazyLoad` 発火時に一度だけ**構築する。起動時間に影響を与えないため。

### 6.2 LazyLoad 前後の差分

プラグインが自身のロード時に登録するコマンド・グローバル keymap は spec に現れない。これを拾うため、スナップショットの差分を取る。

`User LazyLoad` はロード**後**に発火するため、前状態は事前に保持しておく必要がある。手順:

1. `setup()` 時に `nvim_get_commands({ builtin = false })` と、モード `n` / `v` / `x` / `s` / `o` / `i` / `c` / `t` それぞれの `nvim_get_keymap(mode)` のスナップショットを取る
2. `LazyLoad` 発火のたびに現在の状態と比較し、新規分を `event.data`（プラグイン名）に帰属させる
3. スナップショットを更新する

複数プラグインが連鎖ロードされた場合、後続分が最初のプラグインに帰属する可能性があるが、`LazyLoad` はプラグインごとに個別に発火するため実用上の誤差は小さい。

### 6.3 ソースパスからの解決

`vim.keymap.set` フック時に `debug.getinfo` の `source` からプラグインを特定する。`who-called.nvim` の `resolver.lua` の実装を移植する。要点:

- パスが `stdpath("data") .. "/lazy/<name>/"` または lazy の `dev.path` 配下なら `<name>` がプラグイン名
- スタックを遡り、`plenary.nvim` / `nui.nvim` のようなユーティリティプラグインはスキップして実際の呼び出し元を返す
- 解決結果はキャッシュする

`early()` の時点では lazy がまだ利用できないため、この段はパス文字列のパターンマッチのみで完結させ、`lazy.plugins()` に依存しない。

### 6.4 帰属できなかった場合

いずれの段でも解決できないイベントは**破棄する**。`(unknown)` として集計しても棚卸しの判断に使えないため。

## 7. 計測 (`track.lua`)

### 7.1 `load`

`User LazyLoad` の autocmd。`args.data` がプラグイン名。リスクなし。

### 7.2 `cmd`

`CmdlineLeave` の autocmd。

- `vim.fn.getcmdtype() == ":"` のときのみ処理する
- `v:event.abort` が真（Esc でキャンセル）なら無視する
- `getcmdline()` から range 接頭辞（`%`、`1,5`、`'<,'>` 等）を読み飛ばしてコマンド名を抽出する
- `by_cmd` に一致した場合のみカウントする

**限界**: 手で打ったコマンドのみを数える。`<cmd>Telescope<cr>` のような keymap 経由の呼び出しは `CmdlineLeave` を発火しないが、これは `key` として数えられるため取りこぼしにはならない。

### 7.3 `key`

keymap をカウンタでラップして再登録する。対象は2経路。

**(a) LazyLoad 差分で検出したグローバル keymap**

`nvim_get_keymap` はグローバル keymap のみを返すため、この経路が扱うのはグローバル keymap に限られる。buffer-local keymap は (b) の担当。

エントリから元の設定を復元して再登録する。

```
opts = {
  silent  = entry.silent == 1,
  noremap = entry.noremap == 1,
  nowait  = entry.nowait == 1,
  desc    = entry.desc,
}
```

**ラップしない条件**（触れずに素通しし、レポートで「計測不能」として報告する）:

- `entry.callback` が function でない（文字列 rhs）。`feedkeys` で再現すると `noremap` や operator-pending の意味論が変わり、環境を壊すリスクがある
- `entry.expr == 1`。expr マップの評価中は textlock により副作用が制限されるため

**(b) `vim.keymap.set` のグローバルフック**（`hook_keymap_set = true` のとき）

gitsigns の `on_attach` のようにロード後の autocmd で張られる buffer-local keymap は (a) の差分では拾えない。これを拾うため `vim.keymap.set` を差し替える。

```lua
local orig = vim.keymap.set
vim.keymap.set = function(mode, lhs, rhs, opts)
  if type(rhs) == "function" and not (opts and opts.expr) then
    rhs = wrap(source_of_caller(), lhs, rhs)
  end
  return orig(mode, lhs, rhs, opts)
end
```

rhs が function 以外、または `expr` のときは**引数に一切手を触れず**そのまま元の関数に渡す。ラップ済みかどうかは弱参照テーブルで管理し、二重ラップを防ぐ。

このフックは他のプラグインより先に張る必要があるため、`setup()` ではなく `early()` から呼ぶ（後述）。

## 8. 保存 (`store.lua`)

### 8.1 形式

`<store_dir>/YYYY-MM.jsonl` に追記する。1行1プラグイン、内容は**前回 flush からの差分**。

```json
{"t":1755993600,"p":"flash.nvim","load":1,"key":{"s":40,"S":3}}
{"t":1755993600,"p":"telescope.nvim","load":1,"cmd":{"Telescope":12}}
{"t":1755993600,"p":"$session","load":1}
```

- `t`: flush 時刻（Unix 秒）
- `p`: プラグイン名。`$session` はセッション数の分母を数える特別なエントリで、`load` フィールドをセッション数のカウンタとして流用する
- `load` / `cmd` / `key`: 差分カウント。空なら省略

差分方式のため集計は単純な総和になり、クラッシュしても直近の flush 間隔分を失うだけで済む。

### 8.2 並行書き込み

複数の Neovim インスタンスが同じファイルに同時追記する。安全性を確保するため:

- `vim.uv.fs_open(path, "a", 420)` で `O_APPEND` を指定し、`fs_write` を**1行につき1回**呼ぶ。Lua の `io.write` は stdio バッファリングの分割タイミングが不定なので使わない
- 4096 バイト未満の `O_APPEND` 書き込みは分割されないため、行が混ざらない
- 1行が 4096 バイトを超える場合（keymap の種類が極端に多いとき）は複数行に分割する。総和なので分割して問題ない

### 8.3 読み出し

`store_dir` 内の全 `*.jsonl` を読み、行ごとに `pcall(vim.json.decode, line)`。デコードに失敗した行は静かに捨てる（クラッシュ時の書きかけ行の可能性がある）。

### 8.4 flush のタイミング

- `flush_interval` 秒ごと（既定 300）。`vim.uv.new_timer()`
- `VimLeavePre`
- `VimEnter` 直後に `$session` を1回。起動直後に落ちてもセッション数が失われないようにする

flush 後はメモリ上のカウンタをクリアする。

## 9. レポート (`report.lua`)

`:Tally` でスクラッチバッファに描画する。

集計対象は `store` の全記録。ロスターは `require("lazy").plugins()` の全プラグインなので、**一度もロードされていないプラグインも 0 として必ず現れる**。これが棚卸しにおける最重要の出力である。

```
tally   2026-05-01 〜 2026-08-24 / 142 sessions

■ 未ロード
  vim-mql5              0        ft=mql5
  neogen                0        keys 未使用
■ 低頻度
  refactoring.nvim      3 sess   key 4            last 2026-06-12
  diffview.nvim        12 sess   cmd 5            last 2026-07-30
■ 常用
  telescope.nvim      141 sess   key 892  cmd 40  last today
■ passive（判定対象外）
  solarized-osaka, hlchunk, nvim-colorizer
■ 計測不能（文字列 rhs / expr のみ）
  vim-expand-region
```

区分の境界は「未ロード = 0 セッション」「低頻度 = 全セッションの 10% 未満」「常用 = それ以外」。

バッファは `modifiable = false`、`filetype = "tally"`。見出しへのハイライトのみ付ける。

## 10. 設定

```lua
require("tally").setup({
  store_dir       = vim.fn.stdpath("state") .. "/tally",
  flush_interval  = 300,
  passive         = {},      -- Lua パターンのリスト
  hook_keymap_set = true,
  track           = { load = true, cmd = true, key = true },
})
```

`passive` の各要素は Lua パターンとしてプラグイン名に**部分一致**で照合する。`"solarized%-osaka"` は `solarized-osaka.nvim` に一致する。完全一致させたい場合は `"^name$"` と書く。

`passive` は計測を偽装せず、判定対象外であることを明示するための手動タグである。colorscheme や表示系プラグインをここに列挙する。

## 11. 起動シーケンスと組み込み

```lua
{
  "shabaraba/tally.nvim",
  lazy = false,
  priority = 1000,
  init = function() require("tally").early() end,
  opts = { passive = { "solarized-osaka", "hlchunk" } },
}
```

- `early()`: `vim.keymap.set` のフックのみを張る。設定は既定値で判断する。`lazy.setup()` 中に priority 降順で走るため、他プラグインの `init` より先に入る。厳密な最先着は保証されないが実用上は十分
- `setup(opts)`: 設定のマージ、autocmd 登録、スナップショット取得、タイマー起動

`early()` を呼ばなくても動作する。その場合 buffer-local keymap が計測対象から外れるだけで、lazy spec 由来の keymap は問題なく計測される。

## 12. パフォーマンス

| 箇所 | コスト |
|---|---|
| `early()` | 関数を1つ差し替えるのみ |
| `setup()` | autocmd 3個 + タイマー1個 + スナップショット |
| keymap 発火時 | 関数呼び出し1回とテーブルのインクリメント1回 |
| 帰属インデックス構築 | 初回 `LazyLoad` まで遅延 |
| flush | 5分に一度、数十行の小さな書き込み |

`vim-startuptime` で計測して起動時間への影響を確認する。

## 13. プライバシー

記録するのはプラグイン名、コマンド名、keymap の lhs のみ。ファイルパス、cwd、バッファ内容、コマンドの引数は一切記録しない。記録は `stdpath("state")` 配下に留まり、外部送信は行わない。

`vim.on_key` を使わないのはこの方針による。インサートモードの打鍵をすべて拾ってしまうため。

## 14. 既知の限界

- 文字列 rhs および `expr` の keymap は計測できない。レポートで明示する
- Lua API の直接呼び出し（`require("telescope.builtin").find_files()`）は計測しない
- 表示・常駐系プラグインの有用性は計測できない。`passive` タグで除外する
- lazy.nvim 以外のプラグインマネージャには対応しない
- 連鎖ロード時、帰属が先行プラグインに寄る可能性がある

## 15. テスト戦略

plenary.busted を使用し、`nvim --headless -c "PlenaryBustedDirectory tests/"` で実行する。CI は GitHub Actions。

テスト対象:

- `attrib`: lazy spec 形式（文字列 / テーブル / mode のリスト指定）のパース、パスからのプラグイン名抽出
- `store`: JSONL の往復、壊れた行のスキップ、4096 バイト超の分割
- `report`: 集計の総和、区分の境界、ロスターとの突き合わせで未ロードが 0 として現れること
- `track`: コマンド名の抽出（range 接頭辞つきを含む）、ラップ対象外条件の判定

計測フックそのものの結合テストは実 Neovim の状態に依存するため、手動確認とする。

## 16. リポジトリ

```
tally.nvim/
├── lua/tally/
│   ├── init.lua      setup / early / autocmd / flush
│   ├── config.lua    既定値とマージ
│   ├── attrib.lua    帰属解決
│   ├── track.lua     計測
│   ├── store.lua     JSONL
│   └── report.lua    集計と描画
├── plugin/tally.lua  :Tally
├── doc/tally.txt
├── tests/
├── .github/workflows/ci.yml   stylua --check + tests
├── docs/design/
├── README.md
├── LICENSE           MIT
└── .stylua.toml
```

コードコメントは既存の自作プラグイン（`who-called.nvim`、`pile.nvim`）に合わせて日本語・必要最小限とする。README と `doc/tally.txt` は英語。

## 17. who-called.nvim との関係

`who-called.nvim` は「今この UI 要素を出したのはどのプラグインか」を調べるその場のデバッグ用ツールで、`vim.notify`・診断・ウィンドウ・オプションを広くフックする。tally は数ヶ月スパンの常時稼働・永続化が要件でフットプリントを小さく保つ必要があるため、統合せず別プラグインとする。

共有するのは `resolver.lua` のパス解決ロジック約60行のみ。共有ライブラリ化はコストに見合わないため、tally 側に移植する。
