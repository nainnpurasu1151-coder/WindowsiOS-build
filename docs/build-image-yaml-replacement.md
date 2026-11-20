# build-image.yml 差し替え手順（再開可能化）

対象ファイル：`.github/workflows/build-image.yml`（ファイル全体を差し替える）

## 何が変わるか（2026-11-20 修正版）

- 入力 `inputs_run_id` を追加。過去の run の `image-inputs` 成果物
  （インストーラディスク）を再利用し、`phase1` から再開できる
  （`esd_run_id` と同じ仕組み。再利用時は `fetch-inputs` ジョブが取り込む）。
  - `fetch-inputs` は同じ run の `windows-esd` も一緒に取り込む
    （optimize が WinPE 構築に ESD を必要とするため）。ただし
    `esd_run_id` が指定されている場合はそちら（`reuse-esd`）に任せ、
    成果物名の衝突を避けるため ESD の取り込みは行わない。
  - `inputs_run_id` 指定時、`fetch-esd` と `installer` は実行されない。
- **スキップ伝播バグの修正**：run #8 では run 全体が success 表示なのに
  `phase1`／`phase2`／`optimize` が skipped になった。GitHub Actions は
  needs グラフの祖先に skipped があると、状態関数を含む `if` を持たない
  ジョブへスキップを伝播させる（`installer` は `always()` で免れたが、
  `if` の無い `phase1` は直接の needs である installer が成功していても
  スキップされた）。対策として `phase1`／`phase2`／`optimize` に
  `!cancelled() && needs.<ジョブ>.result == 'success'` 形式の明示的な
  `if` を付け、成功判定を結果ベースに変えた。
- （従来分）`fetch-esd`（UUP取得→ISO変換→合成ESD、約40分。成果物は
  `windows-esd` のみ）と `installer` の分割、`esd_run_id` による
  ESD 再利用はそのまま。

## 差し替え手順（GitHub Web）

1. リポジトリの **Code** タブ → `.github` → `workflows` → **build-image.yml** を開く
2. 右上の **鉛筆マーク（Edit）**（無ければ編集画面の直リンクを開く）
3. 中身を **全選択して削除** し、完成品ファイルの全文を貼り付ける
4. **「Commit changes...」→「Commit changes」** で確定
5. Actions タブで **Build Windows 11 machine image** がエラーなく表示されることを確認

## Run のしかた

- **今回の再開（run #8 の続き）**：
  - `inputs_run_id` に **`44523453406`**（run #8）を入れる
  - `esd_run_id` は **空欄**（ESD は `fetch-inputs` が run #8 から一緒に取り込む）
  - `helpers_run_id` は **空欄**（helpers はこの run 内で作り直す）
  - 他はすべてデフォルトのまま Run
  - 流れ：`fetch-inputs` が image-inputs＋windows-esd を取り込み →
    `phase1` → `phase2` → `optimize` → 成果物 `WindowsiOS-Win11-machine`
- **初回（まっさらから）**：すべての run_id を空欄のまま Run
  （fetch から全部実行）。`fetch-esd` が成功したら、その run の ID
  （run ページの URL 末尾の数字）を控えておく。
- **ESD だけ再利用したい時**：控えた run ID を `esd_run_id` に入れて Run。
  fetch（約40分）が丸ごとスキップされ、`installer` から再開される。
- 注意：run #6 以前の run には `windows-esd` 成果物は存在しない
  （旧構成では ESD が prepare ジョブ内部でしか作られなかった）ため、再利用はできない。
  `image-inputs` の再利用は、installer が成功した run（run #8 以降）が対象。
  成果物の保持期間（既定90日）を過ぎた run も再利用できない。
