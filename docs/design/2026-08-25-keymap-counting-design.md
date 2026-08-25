# tally.nvim キーマップ計測の拡張 設計

- 日付: 2026-08-25
- ステータス: 設計確定・実装前
- 前提設計: [2026-08-24-tally-design.md](2026-08-24-tally-design.md)

## 1. 目的

キーマップの押下回数を、rhs の書き方に左右されずに数えられるようにする。

初版は「Lua コールバックを包むときだけ計測する」という保守的な原則を採り、その結果 `<Plug>` マッピングと文字列 rhs のマッピングが構造的に計測不能だった。`:Tally` はそれらを「セッション粒度のみ」として隔離表示していたが、隔離は問題の回避であって解決ではない。使用頻度を知るという本来の目的に対して、測れない領域が残り続ける。

本設計はその穴を塞ぎ、あわせて lhs 単位の内訳と利用者自身のキーマップをレポートに載せる。

## 2. スコープ

### やること

- 文字列 rhs のマッピング（`<Plug>` 系・Ex コマンド系）を押下単位で計測する
- 元から `expr = true` のマッピングを計測対象に含める
- 利用者自身が定義したキーマップを `$user` として帰属させる
- lhs 単位の使用頻度を `:TallyKeys` で表示する。未使用マッピングを含む
- 「セッション粒度のみ」分類を削除する

### やらないこと

- **モード別の集計**。`n` と `x` に張られた同一 lhs は合算する。`<Plug>` 系は複数モードへの登録が常態であり、分離すると読みにくくなるだけで判断材料が増えない
- **`$user` を `:Tally` に出すこと**。`:Tally` はプラグインを消す判断のための画面であり、利用者自身の設定は消す対象ではない
- **バッファローカルマッピングの網羅**。後述の限界を参照
- **`.` によるドットリピートの計上**。マッピングを経由しないため原理的に捕捉できない。仕様として受け入れる

## 3. 計測方式

rhs の種類ごとに3系統に分ける。**関数 rhs の扱いは変更しない**。既存のコールバックラップは安全かつ正確であり、置き換える理由がない。

| 元の rhs | 方式 | マッピング種別の変化 |
|---|---|---|
| function（`expr` なし） | コールバックを包む（現状のまま） | なし |
| function（`expr = true`） | コールバックを包み `inner(...)` の戻り値を返す | なし |
| 文字列（`<Plug>` / `:cmd` / その他） | expr 化し、元の文字列を返す | **ここだけ変わる** |

意味論が変わりうる範囲を文字列 rhs だけに閉じ込めるための分割である。

### 3.1 文字列 rhs の expr 化

```lua
vim.keymap.set(mode, lhs, function()
  counter.add(plugin, "key", lhs)
  return rhs
end, {
  expr = true,
  remap = not noremap,
  replace_keycodes = true,
  silent = silent,
  nowait = nowait,
  desc = desc,
  buffer = buffer,
})
```

`remap = not noremap` が要点である。`<Plug>` は remap されなければ展開されず、逆に `nnoremap Y y$` の `y$` は remap されてはならない。元のマッピングの `noremap` フラグをそのまま引き継ぐことで両立する。

`replace_keycodes = true` により、返した文字列中の `<Plug>(...)` や `<CR>` が正しく解釈される。

### 3.2 検証済みの挙動

Neovim 0.13.0-dev の headless で以下を確認した。実装時に `tests/track_hook_spec.lua` へ移植する。

| 検証項目 | 結果 |
|---|---|
| `<Plug>` マッピングのカウントと内側の実行 | 保たれる |
| 回数プレフィックス（`3gy` → `v:count == 3`） | 保たれる |
| レジスタ指定（`"agy`） | 保たれる |
| オペレータ待機のテキストオブジェクト（`diq`） | 保たれる |
| `operatorfunc` + `g@`（Comment.nvim 系の中核） | 保たれる |
| `noremap` の保全（`$` を別マップに奪われても壊れない） | 保たれる |
| 挿入モードの `<Plug>` | 保たれる |
| `:Cmd<CR>` 形式の文字列 rhs | 保たれる |
| `<Cmd>...<CR>` 形式の文字列 rhs | 保たれる |
| `.` でカウントが二重計上されない | 増えない |
| expr 評価中のテーブル更新（textlock） | 安全 |

`.` はカウントが増えない。マッピングを経由しないため捕捉できず、仕様として受け入れる。連続編集の実回数はカウントを下回りうる。

`<SNR>` を含む Vimscript の rhs（`:call <SNR>27_Bump()<CR>`）も再登録に耐えることを確認した。ただし `replace_keycodes = true` が必須で、`false` ではスクリプトローカル関数の呼び出しが壊れる。

### 3.3 起動時の一掃ラップ

フックは `tally.early()` の時点から有効になるため、それ以前に張られたマッピングは包まれない。Neovim 標準のマッピング（`grn` `gra` `grr` など）と、`early()` より前に読まれる設定が該当する。包まれていないマッピングは押しても数が増えず、`:TallyKeys` で「未使用」として誤って表示される。未使用リストの信頼性に直結するため、放置しない。

`setup()` で全モードの現存マッピングを `nvim_get_keymap` から列挙し、まとめてラップし直す。ラップの方式は §3.1 と同じ。帰属が解決できないものは `$user` に寄せる。

コストは実測で **609件・6.60ms**（Neovim 0.13.0-dev, headless）。1件あたり約0.011ms なので、1500件規模の設定でも20ms 程度に収まる。同期実行で問題ない。実利用で3桁ms に達する場合は `vim.schedule` による遅延実行に切り替える。その場合、遅延中の押下は取りこぼす。

### 3.4 二重ラップの防止

現行コードには既にこの不具合がある。プラグインがロード中に `vim.keymap.set` を呼ぶと、フックが包み、続く `User LazyLoad` の `diff_and_wrap` が同じマッピングをもう一度包む。1回の押下が2カウントされる。実測で確認済み（`gd` を `by_key` 経由で帰属させた場合に `count = 2`）。

`spec_owner` が lhs を解決できない場合は `wrap_existing` が帰属できずに抜けるため、条件によっては表面化しない。だが一掃ラップを足すと、フック済みのマッピングを再び包む経路が増えるため、確実に踏む。

ラップ済みの関数を弱参照テーブルで記録し、既にラップしたものは包まない。

```lua
M._wrapped = setmetatable({}, { __mode = "k" })
-- ラップ時
M._wrapped[wrapper] = true
-- 既存マッピングを包む前
if entry.callback and M._wrapped[entry.callback] then
  return
end
```

lhs ではなく関数の同一性で判定する。同じ lhs が別モードや別バッファに存在しても正しく区別できる。

この修正は今回の変更とは独立した不具合の解消であり、コミットを分ける。

## 4. 帰属

### 4.1 `$user`

`attrib.resolve` に `stdpath("config")` 配下の判定を追加する。プラグインディレクトリのいずれにも該当せず、設定ディレクトリ配下から呼ばれた場合は `$user` を返す。

`$session` という疑似エントリの前例があるため、`counter`・`store` の形式および `report.aggregate` の集計は変更なしで受け入れられる。

`$user` は `:Tally` のロスターには含めない。`:TallyKeys` にのみ現れる。

### 4.2 解決順序

既存の順序を変えない。lazy spec の `keys` 宣言（`spec_owner`）が最優先、外れた場合にスタック解決（`attrib.resolve`）へ落ちる。`$user` はスタック解決の末端に位置する。

## 5. データモデル

**変更しない。**

`counter.add(plugin, "key", lhs)` は既に lhs 単位で保持し、`store.encode` も lhs 単位で JSONL に書き、`report.aggregate` も `p.key[lhs]` を復元している。lhs 単位の内訳表示に必要なデータは既に蓄積されており、描画が存在しないだけである。

既存の記録との互換性も保たれる。読み出し側のスキーマが変わらないため、移行処理は不要。

## 6. レポート

### 6.1 API の分離

`:Tally` と `:TallyKeys` は別モジュール・別コマンドとする。サブコマンド引数による分岐は採らない。

| コマンド | 実装 | 目的 |
|---|---|---|
| `:Tally` | `require("tally.report").show()` | プラグインを消す判断 |
| `:TallyKeys` | `require("tally.keys").show()` | マッピングを見直す判断 |

`lua/tally/keys.lua` を新設する。`report.lua` は既に159行あり分類ロジックが詰まっているため、そこへは足さない。

### 6.2 未使用マッピングの検出

ストアには押されたマッピングしか記録がない。「張ったのに使っていないマッピング」を出すには、現存するマッピングの一覧が必要になる。

`:TallyKeys` の実行時に `nvim_get_keymap` で全モードの現存マッピングを列挙し、集計と突き合わせる。集計に現れず現存するものが未使用として浮かぶ。プラグイン側の未ロード判定が lazy のロスターとの突き合わせで成り立っているのと同じ構造である。

`nvim_get_keymap` は `<Plug>(...)` 自体を lhs とするエントリも返す（検証済み）。これらはプラグインの内部実装であって利用者が押すものではないため、列挙から除外する。

### 6.3 表示

```
tally keys   142 sessions

■ 未使用  見直し候補
     0  <leader>xx       $user
     0  gr               refactoring.nvim
■ 低頻度
     3  <leader>gs       $user
■ 常用
  1204  jj               $user
   892  <leader>ff       telescope.nvim
```

分類は押下回数で決める。`report.classify` が `max(1, floor(sessions * 0.1))` をセッション数に対して使うのと同じ式を、押下回数に対して適用する。

| グループ | 条件 |
|---|---|
| 未使用 | 押下回数が 0 |
| 低頻度 | 1 以上かつ `max(1, floor(sessions * 0.1))` 未満 |
| 常用 | それ以上 |

低頻度は「10セッションに1回も押していない」という意味になる。各グループ内は押下回数の降順、同数なら lhs の昇順で並べる。

### 6.4 「セッション粒度のみ」の削除

`<Plug>` が押下単位で数えられるようになるため、`report.session_only` は条件を満たすプラグインが原理上存在しなくなる。関数、分類グループ、`render` の該当ブロック、関連テストを削除する。

`attrib.rhs_kind` と `idx.kinds` の利用箇所は `report.session_only`（`report.lua:41,45`）のみであることを確認済みである。`session_only` の削除にともなって次も削除する。

- `attrib.rhs_kind`
- `attrib.build` の `idx.kinds` 構築
- `attrib.parse_keys` が返す `rhs_kind` フィールド
- `tests/attrib_spec.lua` の該当テスト

## 7. 設定

新規の設定項目は追加しない。既存の `track.key` と `hook_keymap_set` が、計測全体を止める逃げ道として機能する。

マッピング個別の除外リストは、必要になってから追加する。

## 8. 既知の限界

- **バッファローカルマッピング**。`vim.keymap.set` フック経由なら `opts.buffer` ごと捕捉できるが、`User LazyLoad` 差分と起動時の一掃はどちらも `nvim_get_keymap`（グローバルのみ）を見ているため、フックより前に張られたバッファローカルなマッピングは取りこぼす。フック後に LSP の `on_attach` や ftplugin が張るものは捕捉できる
- **ドットリピート**。`.` はカウントされない
- **文字列 rhs のマッピング種別が変わる**。`maparg` で覗くと expr マッピングとして見える。他プラグインがマッピング定義を読み取って分岐している場合、影響しうる
- **一掃ラップは `setup()` 時点のスナップショット**。それ以降に他プラグインが `vim.keymap.set` を経由せず `nvim_set_keymap` で直接張ったものは捕捉できない

## 9. テスト戦略

- `tests/track_hook_spec.lua` に §3.2 の検証項目を移植する。`<Plug>`、`operatorfunc` + `g@`、レジスタ、オペレータ待機、挿入モード、`noremap` 保全、`<SNR>` を含む rhs
- `tests/track_hook_spec.lua` に二重ラップの回帰テストを追加する。フックと `diff_and_wrap` の両方を通したマッピングを1回押して、カウントが1であること
- `tests/track_spec.lua` に一掃ラップのテストを追加する。`setup()` 前に張ったマッピングが計測対象になること、`<Plug>` 接頭辞の lhs が除外されること
- `tests/keys_spec.lua` を新設し、集計と現存マッピングの突き合わせ、分類、描画を検証する
- `tests/attrib_spec.lua` に `$user` 解決のケースを追加し、`rhs_kind` のテストを削除する
- `tests/report_spec.lua` から `session_only` のテストを削除する

## 10. 影響範囲

| ファイル | 変更 |
|---|---|
| `lua/tally/track.lua` | 二重ラップの防止、文字列 rhs の expr ラップ、expr マッピングのラップ、起動時の一掃 |
| `lua/tally/attrib.lua` | `$user` 解決の追加、`rhs_kind` と `kinds` の削除 |
| `lua/tally/report.lua` | `session_only` と関連分類の削除 |
| `lua/tally/keys.lua` | 新規 |
| `lua/tally/init.lua` | `setup()` からの一掃呼び出し |
| `plugin/tally.lua` | `:TallyKeys` の登録 |
| `README.md` | Limitations の書き換え、`:TallyKeys` の追記 |
| `doc/tally.txt` | 同上 |

## 11. 実装順序

1. 二重ラップの防止（既存不具合の修正。単独でコミットする）
2. 文字列 rhs と expr マッピングのラップ
3. 起動時の一掃ラップ
4. `$user` 帰属
5. `session_only` と `rhs_kind` の削除
6. `:TallyKeys`
7. ドキュメント

1 を先に片付けないと、2 以降のカウントが検証できない。
