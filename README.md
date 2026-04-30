# Blackjack — Spinel AOT + WebAssembly

**▶ https://machida.github.io/bj/**

ブラウザで遊べるブラックジャック。ゲームロジックを **Ruby** で書き、
[Spinel](https://github.com/matz/spinel) AOT コンパイラで **C** に変換し、
[Emscripten](https://emscripten.org/) で **WebAssembly** にコンパイルする。

```
blackjack.rb  ──[Spinel]──▶  blackjack.c  ──[Emscripten]──▶  blackjack.wasm
   Ruby             AOT            C                WASM          ブラウザ実行
  (230行)        コンパイル       (387行)          (36 KB)
```

---

## 動かし方

### 必要なもの

| ツール | 用途 | インストール |
|--------|------|-------------|
| Ruby 3.x | Spinel のビルドに必要 | `brew install ruby` |
| Emscripten | C → WASM コンパイル | `brew install emscripten` |
| Python 3.10+ | Emscripten の依存 | `brew install python@3.13` |
| GNU make | ビルド自動化 | macOS 標準搭載 |

### ビルド

```sh
# Spinel のクローン＆ビルド → Ruby → C → WASM をすべて一発で
make

# 動作確認
make check

# 開発サーバー起動
make serve
# → http://localhost:8080 をブラウザで開く
```

初回は Spinel のビルド（数分）と Emscripten のキャッシュ生成が走る。
2回目以降は差分だけ再コンパイルされる。

### macOS で emcc が Python エラーになる場合

Homebrew の emcc は Python 3.10+ を要求するが、macOS 標準の python3 は
3.9 系のことがある。`EMSDK_PYTHON` を指定して回避する：

```sh
EMSDK_PYTHON=/opt/homebrew/opt/python@3.13/bin/python3.13 make
```

`Makefile` 冒頭の `EMSDK_PYTHON` 変数を編集しても良い。

---

## ファイル構成

```
.
├── src/
│   └── blackjack.rb        # ゲームロジック（Ruby・Spinel 方言）
├── generated/
│   └── blackjack.c         # Spinel が生成した C コード ※編集不要
├── docs/
│   ├── index.html          # UI（HTML + CSS インライン）
│   ├── game.js             # JS ブリッジ（WASM ↔ DOM）
│   ├── blackjack.js        # Emscripten 生成グルーコード ※編集不要
│   └── blackjack.wasm      # WebAssembly バイナリ ※編集不要
├── spinel/                 # matz/spinel クローン（make 時に自動取得）
└── Makefile
```

---

## Spinel とは

[Spinel](https://github.com/matz/spinel) は **Ruby の AOT（Ahead-of-Time）コンパイラ**。
Ruby ソースに全体プログラム型推論をかけて最適化された C コードを生成し、
ネイティブバイナリにコンパイルする。作者は Ruby の作者・まつもとゆきひろ（matz）。

- CRuby 比で **幾何平均 11.6 倍高速**（計算集約的な処理では最大 86 倍）
- コンパイラ自身も Ruby で書かれており、**セルフホスト**を達成している
- 生成物はスタンドアロンバイナリ（ランタイム不要）

このプロジェクトでは Spinel の **`-S` フラグ**（C コードを stdout に出力）を使い、
生成された C を Emscripten に渡すことで WASM として動作させている。

---

## コンパイルパイプラインの詳細

### ステップ 1: Ruby → C（Spinel）

```sh
./spinel/spinel src/blackjack.rb -S > generated/blackjack.c
```

Spinel は Ruby を解析して**全体プログラム型推論**を行い、型付きの C コードを生成する。
たとえば `hand_score(hand)` という Ruby の関数は：

```ruby
# Ruby (src/blackjack.rb)
def hand_score(hand)
  total = 0
  aces  = 0
  i = 0
  while i < hand.length
    p = card_points(hand[i])
    if p == 11
      aces += 1
    end
    total += p
    i += 1
  end
  while total > 21 && aces > 0
    total -= 10
    aces  -= 1
  end
  total
end
```

`hand` が Integer の配列だと推論され、以下の C に変換される：

```c
// C (generated/blackjack.c) — Spinel が自動生成
static mrb_int sp_hand_score(sp_IntArray * lv_hand) {
    mrb_int lv_total = 0;
    mrb_int lv_aces  = 0;
    mrb_int lv_i     = 0;
    mrb_int lv_p     = 0;
    SP_GC_SAVE();
    SP_GC_ROOT(lv_hand);
    lv_total = 0; lv_aces = 0; lv_i = 0;
    mrb_int _t1 = sp_IntArray_length(lv_hand);
    while ((lv_i < _t1)) {
      lv_p = sp_card_points(sp_IntArray_get(lv_hand, lv_i));
      if ((lv_p == 11)) { lv_aces += 1; }
      lv_total += lv_p;
      lv_i += 1;
    }
    while (((lv_total > 21) && (lv_aces > 0))) {
      lv_total -= 10;
      lv_aces  -= 1;
    }
    return lv_total;
}
```

引数型（`sp_IntArray*`）、変数型（`mrb_int`）、GC ルートの登録（`SP_GC_ROOT`）まで
すべて Spinel が推論・生成する。

### ステップ 2: C → WASM（Emscripten）

```sh
emcc generated/blackjack.c \
  -I spinel/lib \
  -O2 \
  -Dmalloc_trim(x)=((void)(x)) \   # Emscripten にない関数を no-op 化
  -sMODULARIZE=1 \                 # JS ファクトリ関数としてラップ
  -sEXPORT_NAME=createBlackjack \
  -sEXIT_RUNTIME=1 \
  -sFORCE_FILESYSTEM=1 \
  -sINVOKE_RUN=0 \                 # main() を自動実行しない
  "-sEXPORTED_RUNTIME_METHODS=['callMain','FS']" \
  -lm \
  -o docs/blackjack.js
```

Spinel のランタイム（`sp_runtime.h`）には GC、文字列管理、配列実装が含まれており、
これをまるごと WASM に載せている。

### ステップ 3: WASM ↔ JavaScript（stdin/stdout ブリッジ）

ゲームロジック（Spinel 生成 WASM）と UI（JavaScript）は **stdin/stdout** で通信する。
ボタンを押すたびに新しい WASM インスタンスを生成し（プリコンパイル済みバイナリを再利用）、
コマンドを stdin として渡し、出力を stdout から受け取る。

```
JS              WASM (Spinel 生成)
─────────────────────────────────────────────────────
stdin  ──▶   "hit|1000|100|48291|9,45|32,35|38,40,…"
             └──┘ └──┘ └──┘ └───┘ └──┘  └───┘ └──┘
            cmd chips bet seed player dealer  残デッキ

stdout ◀──   "gameover|bust|900|100|Bust! You lose.|9,45,30|32,35|…"
             └──────┘ └──┘ └──┘ └──┘ └───────────┘
            phase  result chips bet    message
```

カードは 0〜51 の整数で符号化（`suit = card / 13`、`value = card % 13`）。

```js
// game.js の核心部分
async function wasmRun(inputStr) {
  const bytes = new TextEncoder().encode(inputStr + '\n');
  let pos = 0, output = '';

  const M = await createBlackjack({
    noInitialRun: true,
    stdin:    () => pos < bytes.length ? bytes[pos++] : null,
    print:    (line) => { output = line; },
    printErr: () => {},
  });

  try { M.callMain([]); }
  catch (e) { /* ExitStatus は正常終了 */ }

  return output;
}
```

---

## Spinel 方言について

Spinel は Ruby の全機能をサポートしているわけではない。
このプロジェクトで**避けた**Ruby の機能と、その理由：

| 避けた機能 | 理由 |
|-----------|------|
| `Fiber` | `ucontext.h` を使うため WASM 非対応 |
| `rand` | Spinel から Ruby の `rand` を呼べないため、LCG を自前実装 |
| 多値返却 `a, b = func()` | 混合型配列（`PolyArray`）が生成され Emscripten で型エラー |
| `eval` / メタプログラミング | Spinel 非対応 |

乱数は次の LCG（線形合同法）をRubyで実装し、JS から seed を渡している：

```ruby
$rng = seed
def rng_next(max)
  $rng = ($rng * 1664525 + 1013904223) % 2147483647
  $rng % max
end
```

---

## ゲームルール

- 初期チップ **$1,000**、最低ベット **$10**
- ブラックジャック（最初の2枚で 21）は **1.5倍**払い
- ディーラーは **17 以上**になるまで必ずヒット（ソフト 17 も含む）
- ベット変更は各ゲームの開始前のみ可能

---

## 開発メモ

### Emscripten で `malloc_trim` がないエラー

Spinel のランタイムヘッダ（`sp_runtime.h`）は非 Apple / 非 Windows 環境で
`malloc_trim(0)` を呼ぶが、Emscripten の libc に宣言がない。
コンパイル時に `-Dmalloc_trim(x)=((void)(x))` で no-op に置き換えている。

### 毎回 WASM インスタンスを作り直す理由

Spinel が生成する C コードの `main()` は1回限りの実行を前提としており、
グローバル変数の初期化が再実行に対応していない。
そのため `callMain()` を複数回呼ぶと GC 状態が壊れる可能性がある。
対策として毎回新しいインスタンスを生成しているが、WASM バイナリは
`ArrayBuffer` としてキャッシュするため再取得は発生しない。
カードゲーム程度のデータ量では体感できるパフォーマンス差はない。
