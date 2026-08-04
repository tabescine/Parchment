-- Parchment test runner. No dependencies; runs under plain Lua 5.1:
--
--   lua5.1 Tests/run.lua        (from the repo root)
--
-- Each test file is a standalone script of asserts - a file passes when it
-- runs to completion. Files run in-process in manifest order, and every file
-- installs the globals it needs itself (never relying on a previous file's).
-- WoW ignores this directory (it is not in the .toc); it ships harmlessly,
-- like Tools/.
local MANIFEST = {
    "test_core.lua",
    "test_schema.lua",
    "test_packs.lua",
    "test_codecs.lua",
    "test_codec_fidelity.lua",
    "test_charactersheet.lua",
    "test_effects_vocab.lua",
    "test_items.lua",
    "test_picks.lua",
    "test_feats.lua",
    "test_spells.lua",
    "test_homebrew.lua",
    "test_chatlinks.lua",
    "test_dice.lua",
    "test_initiative.lua",
    "test_init_adopt.lua",
    "test_init_scale.lua",
    "test_widgets.lua",
    "test_widgets_debounce.lua",
    "test_characterform.lua",
    "test_leveling.lua",
    "test_importexport.lua",
    "test_pack_flow.lua",
    "test_comm.lua",
    "test_comm_trust.lua",
    "test_comm_hardening.lua",
    "test_comm_compress.lua",
    "test_sharing.lua",
    "test_party.lua",
    "test_menu.lua",
    "test_samples.lua",
}

-- Repo root, derived from how the runner was invoked (handles absolute and
-- relative paths; "" means the current directory is the root).
TEST_ROOT = ((arg and arg[0]) or ""):match("^(.*)Tests[/\\]run%.lua$") or ""

local failed = 0
for _, file in ipairs(MANIFEST) do
    local ok, err = pcall(dofile, TEST_ROOT .. "Tests/" .. file)
    if ok then
        io.write("PASS  ", file, "\n")
    else
        failed = failed + 1
        io.write("FAIL  ", file, "\n      ", tostring(err), "\n")
    end
end
io.write(string.rep("-", 40), "\n")
if failed > 0 then
    io.write(failed, " file(s) FAILED\n")
    os.exit(1)
end
io.write(#MANIFEST, " files passed\n")
