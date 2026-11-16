-- Only the Telegram bot's anonymous-key request path needs to consume a pairing code.
revoke execute on function public.complete_telegram_link(text,bigint,text) from authenticated;
grant execute on function public.complete_telegram_link(text,bigint,text) to anon;
