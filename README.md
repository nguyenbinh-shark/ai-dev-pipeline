# ai-dev-pipeline

Quy trình phát triển nhiều agent dùng chung cho mọi git repository:

| Bước | Agent | Quyền |
|---|---|---|
| Lập kế hoạch → `.ai/plan.md` | Claude Code (`claude`) | chỉ đọc + `git status/diff/log/show` |
| Implement / fix | Gemini qua Antigravity (`agy`) | chỉ sửa file, **không shell**, sandbox |
| Validation | pipeline chạy `.ai/validate.sh` | agent không tự chạy |
| Audit → `.ai/review.json` | Codex (`codex exec`) | sandbox read-only, output theo JSON schema |
| Tóm tắt → `.ai/summary.md` | Claude Code | chỉ đọc |

Vòng lặp validate → audit → fix chạy tối đa 3 lần audit. Kết quả FAIL cuối cùng thì exit khác 0.
Pipeline **không bao giờ** commit, push, reset, clean, stash, checkout hay restore.

## Yêu cầu

- Linux, `bash`, `git`, `python3` (chỉ dùng thư viện chuẩn), GNU `timeout` và `sha256sum`.
- Ba CLI, đã đăng nhập:
  - `claude`: extension Claude Code hoặc bản CLI.
  - `agy`: Antigravity CLI, thường ở `~/.gemini/bin/agy`.
  - `codex`: extension OpenAI/Codex hoặc bản CLI.
- Pipeline tìm CLI theo thứ tự: biến `AI_*_BIN`, rồi `PATH`, rồi thư mục extension VS Code có
  phiên bản mới nhất. Symlink trỏ vào thư mục extension sẽ hỏng khi extension cập nhật, nên
  bước tìm theo phiên bản mới nhất là cần thiết.

## Cài đặt (một lần cho mỗi máy)

```bash
git clone <repo này> ~/ai-dev-pipeline      # hoặc copy thư mục
~/ai-dev-pipeline/install.sh                # symlink ~/.local/bin/ai-pipeline, không cần sudo
ai-pipeline doctor                          # kiểm tra CLI, đăng nhập, model
```

Toolkit (script, prompt, schema) nằm **ngoài** repo dự án. Agent sửa repo dự án không thể sửa
pipeline. Cập nhật toolkit một lần thì mọi dự án đều dùng bản mới.

## Dùng cho một dự án

```bash
cd ~/my-project
ai-pipeline init                 # tạo .ai/pipeline.conf, .ai/validate.sh, AGENTS.md, CLAUDE.md
                                 # (không ghi đè file đã có)
$EDITOR .ai/validate.sh          # điền STEPS = lệnh build/test offline thật của dự án,
                                 # rồi xóa dòng '# AI-PIPELINE: UNCONFIGURED'
ai-pipeline --validate-only      # validation phải PASS trước khi giao việc cho agent
$EDITOR AGENTS.md                # điền phần TODO: mô tả repo, quy tắc bắt buộc
```

`init` chỉ **gợi ý** lệnh validation (Makefile, package.json, pytest, cargo, go, cmake, colcon).
Nó không tự điền: bạn quyết định lệnh nào đúng.

Chạy một task:

```bash
ai-pipeline --task "Thêm X vào Y" --plan-only   # Claude viết .ai/plan.md; đọc và sửa nếu cần
ai-pipeline --skip-plan                         # implement → validate → audit → fix
ai-pipeline --task "…"                          # chạy liền một mạch
ai-pipeline --task-file task.md --tier hard     # task khó: effort cao hơn
```

Sau khi chạy xong: xem `.ai/summary.md` (có bảng token), `.ai/review.json` và
`.ai/logs/<run>/`. Rồi tự `git diff` và tự commit.

## File trong dự án

| File | Vai trò |
|---|---|
| `.ai/validate.sh` | Validation offline: `STEPS=("name\|timeout\|command" …)`, `GATE_STEPS`, `CLEAN_ENV`, `SETUP`. Hợp đồng: nhận `<out_dir>`, ghi `summary.json`. |
| `.ai/pipeline.conf` | Cấu hình dự án, được source như bash. Viết theo dạng `: "${VAR:=value}"` để biến môi trường cùng tên vẫn thắng. |
| `.ai/prompts/*.md` | Tùy chọn: ghi đè prompt mặc định của toolkit theo tên file. |
| `AGENTS.md` | Quy tắc chung mọi agent đều cần (Codex và agy tự nạp). Giữ ngắn: mỗi dòng tốn token ở **mọi** request. |
| `CLAUDE.md` | `@AGENTS.md` + vai trò của Claude. |
| `.ai/.gitignore` | Bỏ qua output của các lần chạy (`logs/`, `review.json`, `summary.md`, `plan.md`). |

Thiết lập trong `pipeline.conf`:

- `AI_PROTECTED_FILES=(…)`: file agent không được sửa, ví dụ script build mà validation dùng.
  Toolkit, `.ai/validate.sh`, `.ai/pipeline.conf`, `.ai/prompts/*`, `AGENTS.md`, `CLAUDE.md` và
  `GEMINI.md` luôn được bảo vệ.
- `AI_AUDIT_FOCUS`: điểm Codex cần chú ý riêng trong dự án (ví dụ thread safety, timing thời gian thực).
- `AI_REPORT_LANG`: ngôn ngữ của summary. Mặc định English.
- Model/tier: xem phần dưới.

Ví dụ hoàn chỉnh cho workspace ROS 2/colcon: [examples/ros2-colcon/](examples/ros2-colcon/).

## Model và chi phí

| | normal (mặc định) | hard (`--tier hard`) |
|---|---|---|
| Gemini (agy) | `gemini-3.8-flash`, effort medium | `gemini-3.8-flash`, effort high |
| Codex | `gpt-5.6-sol`, effort medium | `gpt-5.6-sol`, effort high |
| Claude | mặc định của CLI | mặc định của CLI |

- Ghi đè bằng các biến `AI_AGY_MODEL`, `AI_AGY_EFFORT`, `AI_CODEX_MODEL`, `AI_CODEX_EFFORT`,
  `AI_CLAUDE_MODEL`, `AI_CLAUDE_EFFORT`. Ví dụ: `AI_CODEX_MODEL=gpt-6-astra` khi cần audit kỹ
  hơn và chấp nhận tốn quota hơn.
- Muốn dùng id đã kèm sẵn effort (`gemini-3.8-flash-low`) thì đặt `AI_AGY_EFFORT=`.
- Trước khi gọi bất kỳ agent nào, pipeline đối chiếu model và effort với `agy models` và
  `codex debug models`. Sai thì dừng với exit 2. **Không bao giờ âm thầm fallback** sang model khác.

**Token:** mỗi lần gọi agent được ghi vào `.ai/logs/<run>/usage.jsonl`, lấy đúng các trường CLI
báo, không ước lượng. Bảng tổng hợp được nối vào cuối `summary.md`. Chú ý:
- Codex không báo tên model thực tế, nên cột này ghi `unavailable`.
- Gemini có cảnh báo khi một lần gọi vượt `40k + 20k × số file liên quan`. Cảnh báo không dừng pipeline.

Những gì đã tối ưu, đều có đo trên task thử:
- Mỗi request của agy tốn sẵn khoảng 13–15k token context cố định. Prompt vì vậy nhắm vào việc
  **giảm số lượt**: plan được đưa thẳng vào prompt, đọc file song song, không đọc lại sau khi sửa,
  không khám phá repo. Kết quả: −30% token của Gemini.
- Codex nhận plan, diff và validation digest ngay trong prompt, và được dặn không đọc lại hay chạy
  lại test. Các feature Codex không dùng (plugins, apps, multi_agent, …) bị tắt. Kết quả: −49%
  input của Codex, vẫn bắt được bug cố ý trong các bài kiểm tra đối chứng.
- Vòng fix chỉ nhận finding critical/major, lỗi validation mới và các file bị ảnh hưởng. Audit
  follow-up chỉ xem patch kể từ lần audit trước.
- Nếu cùng một finding còn sau `AI_FINDING_MAX_FIXES` (mặc định 2) lần fix: pipeline dừng và
  Claude phân tích nguyên nhân (escalation).

## Bảo đảm an toàn

- **Thay đổi dở của bạn được giữ nguyên.** Pipeline snapshot working tree bằng một git index
  tạm (không đụng index thật, HEAD hay stash). Phần được review chỉ là
  `git diff BASE_TREE CURRENT_TREE`.
- **Sửa file được bảo vệ** (sha256) hoặc làm HEAD thay đổi: dừng với exit 4 và **không revert**
  gì, để bạn tự kiểm tra.
- **Gemini** chạy `--mode accept-edits --sandbox` và không được cấp quyền shell. Các lệnh cần xin
  quyền đều bị từ chối, và pipeline cảnh báo qua `denied_actions`.
- **Codex** chạy `-s read-only`, output bị ép theo `schema/review.schema.json`.
- **Điều kiện PASS:** không còn finding critical/major, auditor nói PASS, và không có bước
  validation nào hỏng mới so với baseline.
- **Ctrl-C/SIGTERM** dừng cả agent con, gỡ lock, exit 130. Tại mỗi thời điểm chỉ một lần chạy
  trên mỗi repo (lock `.ai/logs/.lock`).
- **Log** không ghi token hay secret.

Exit code: 0 PASS · 1 FAIL · 2 lỗi dùng/cấu hình · 3 một bước agent lỗi · 4 file được bảo vệ hoặc HEAD bị đổi.

## Những điểm cần biết về CLI (đã kiểm chứng)

- `codex exec` treo nếu stdin không phải `/dev/null`. Pipeline đã xử lý việc này.
- `agy -p` ở chế độ headless tự **từ chối** mọi tool cần xin quyền, nhưng vẫn báo `SUCCESS`.
  File chỉ sửa được bên trong một project agy đã đăng ký (thư mục có trong
  `~/.gemini/config/projects/*.json`). Pipeline tự tìm project này, hoặc dùng `--new-project`.
- Quy tắc cho phép shell của agy chỉ có hiệu lực ở cấp global. Đó là lý do Gemini không có shell
  và pipeline tự chạy validation.
- `codex --disable <feature lạ>` sẽ lỗi. Pipeline chỉ tắt những feature có trong
  `codex features list`.

## Kiểm thử toolkit

```bash
tests/run-tests.sh      # CLI giả, không tốn token, khoảng 30 giây
```

Bộ test gồm: init, validate chưa cấu hình, PASS/FAIL/escalation, fixer không sửa gì, regression
validation, sửa file được bảo vệ (toolkit và dự án), model/effort/tier sai, plan-only, prompt
override, SIGTERM. Mỗi kịch bản còn kiểm tra: thay đổi của người dùng còn nguyên, không có
commit/stash, lock đã được gỡ.

## Cấu trúc

```
bin/ai-pipeline        entry point: init | doctor | chạy pipeline
lib/pipeline.sh        vòng lặp chính
lib/pipeline_lib.py    digest validation, trích plan, phát hiện finding lặp, token, preflight
lib/init.sh, doctor.sh
prompts/               prompt mặc định (plan, implement, fix, audit, audit-followup, summary)
schema/                review.schema.json
templates/             file init tạo cho dự án
examples/ros2-colcon/  validate.sh + pipeline.conf mẫu cho ROS 2
tests/                 run-tests.sh + CLI giả
```
