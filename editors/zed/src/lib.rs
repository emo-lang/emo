use zed_extension_api::{self as zed, LanguageServerId, Result, Worktree};

const DEFAULT_SERVER_PATH: &str =
    "/Users/daqing/mzevo/open-source/emo-lang/emo/editors/vscode/server/emo-lsp";

struct EmoExtension;

impl zed::Extension for EmoExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<zed::Command> {
        let settings =
            zed::settings::LspSettings::for_worktree(language_server_id.as_ref(), worktree)?;

        let (path, args, env) = match settings.binary {
            Some(binary) => (binary.path, binary.arguments, binary.env),
            None => (None, None, None),
        };

        Ok(zed::Command {
            command: path.unwrap_or_else(|| DEFAULT_SERVER_PATH.to_string()),
            args: args.unwrap_or_default(),
            env: env.map(|env| env.into_iter().collect()).unwrap_or_default(),
        })
    }
}

zed::register_extension!(EmoExtension);
