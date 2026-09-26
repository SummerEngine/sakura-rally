"""fal generation specs (model + exact params) for music and ambience layers.

Keyed by cache name; falcache.generate(name, **spec) is a no-op when cached.
"""

EL_MUSIC = "elevenlabs/music/v2.5"
SA3 = "fal-ai/stable-audio-3/medium/text-to-audio"
EL_SFX = "fal-ai/elevenlabs/sound-effects/v2"

_MENU_PROMPT = (
    "Calm, dreamy instrumental lo-fi city-pop with Japanese instrumentation for a video game "
    "main menu. 84 BPM, 4/4, key of D major. Warm Rhodes electric piano chords, gentle koto "
    "melody and plucked koto arpeggios, soft breathy shakuhachi flute phrases, round mellow "
    "bass, light brushed drum kit with soft kick and rim clicks, subtle tape warmth. Spring "
    "cherry blossom mood, peaceful and polished, studio quality mix. Short gentle intro, then a "
    "steady consistent groove at the same tempo throughout, no big ending, no fade out. "
    "Instrumental only, no vocals."
)

MUSIC = {
    "music_menu_el": {"model": EL_MUSIC, "params": {
        "prompt": _MENU_PROMPT, "music_length_ms": 150000, "force_instrumental": True,
        "output_format": "mp3_44100_192"}},
    "music_drive_el": {"model": EL_MUSIC, "params": {
        "prompt": (
            "Steady, sparse instrumental city-pop groove with Japanese instrumentation for a "
            "relaxed driving game, played underneath loud car engine sound. 104 BPM, 4/4, key of "
            "D major. Tight crisp drums with clean hi-hats and snappy rimshot, occasional taiko "
            "drum accents, clean funky electric guitar chops, bright koto hook melody, light "
            "shamisen fills, airy high synth pad. Keep the low-mids and bass light and clean: "
            "small tight bass, no thick pads, no muddy low end, lots of space in the arrangement. "
            "Upbeat but chill, polished modern mix. Consistent tempo and energy throughout, no "
            "fade out, no ending. Instrumental only, no vocals."),
        "music_length_ms": 160000, "force_instrumental": True, "output_format": "mp3_44100_192"}},
    "music_results_el": {"model": EL_MUSIC, "params": {
        "prompt": (
            "Warm, celebratory but calm instrumental city-pop loop with Japanese instrumentation "
            "for a race results screen. 92 BPM, 4/4, key of D major. Sparkling Rhodes chords, "
            "joyful koto arpeggios, soft shakuhachi melody, gentle taiko accents and a light drum "
            "groove, warm round bass. Content, proud, relaxed feeling, polished studio mix. "
            "Consistent tempo throughout, no fade out, no ending. Instrumental only, no vocals."),
        "music_length_ms": 70000, "force_instrumental": True, "output_format": "mp3_44100_192"}},
}

_SFX_FMT = "mp3_44100_192"

SFX = {
    # ---- hanami (spring mountain noon)
    "amb_hanami_breeze": {"model": EL_SFX, "params": {
        "text": "Gentle spring breeze softly rustling through leafy trees on a quiet mountainside, "
                "soft continuous wind in foliage, calm and airy, no birds, no people",
        "loop": True, "duration_seconds": 22, "prompt_influence": 0.5, "output_format": _SFX_FMT}},
    "amb_hanami_stream": {"model": EL_SFX, "params": {
        "text": "Distant small mountain stream gently babbling over rocks, soft continuous "
                "trickling water heard from far away, calm, no birds",
        "loop": True, "duration_seconds": 22, "prompt_influence": 0.5, "output_format": _SFX_FMT}},
    "amb_uguisu_1": {"model": EL_SFX, "params": {
        "text": "Japanese bush warbler (uguisu) singing its famous call 'hoo-hokekyo' once in a "
                "quiet spring forest, clear single bird, natural, slightly distant, no other sounds",
        "duration_seconds": 6, "prompt_influence": 0.6, "output_format": _SFX_FMT}},
    "amb_uguisu_2": {"model": EL_SFX, "params": {
        "text": "A single Japanese bush warbler calling 'hoo-hokekyo' from a nearby tree in "
                "spring, long rising whistle followed by a quick warble, clean recording, quiet "
                "background",
        "duration_seconds": 6, "prompt_influence": 0.6, "output_format": _SFX_FMT}},
    "amb_spring_birds": {"model": EL_SFX, "params": {
        "text": "Small songbirds chirping sparsely in spring trees on a mountain, distant, "
                "occasional soft tweets and short melodic calls, quiet, no wind, no water",
        "duration_seconds": 15, "prompt_influence": 0.5, "output_format": _SFX_FMT}},
    # ---- momiji (autumn golden hour)
    "amb_momiji_wind": {"model": EL_SFX, "params": {
        "text": "Soft autumn evening wind blowing through a valley of maple trees, gentle slow "
                "gusts with dry leaves rustling in the branches, continuous, calm, no birds",
        "loop": True, "duration_seconds": 22, "prompt_influence": 0.5, "output_format": _SFX_FMT}},
    "amb_suzumushi": {"model": EL_SFX, "params": {
        "text": "Japanese bell crickets (suzumushi) chirping at dusk in autumn grass, soft "
                "ringing insect chorus, continuous, calm, gentle and distant, no wind",
        "loop": True, "duration_seconds": 22, "prompt_influence": 0.5, "output_format": _SFX_FMT}},
    "amb_crows_1": {"model": EL_SFX, "params": {
        "text": "Two or three distant crows cawing far away across an autumn valley at sunset, "
                "spacious and echoing, quiet background",
        "duration_seconds": 6, "prompt_influence": 0.6, "output_format": _SFX_FMT}},
    "amb_crows_2": {"model": EL_SFX, "params": {
        "text": "A single crow cawing a few times in the distance over mountains in the evening, "
                "natural outdoor recording, quiet background",
        "duration_seconds": 5, "prompt_influence": 0.6, "output_format": _SFX_FMT}},
    "amb_leaves": {"model": EL_SFX, "params": {
        "text": "Dry autumn leaves rustling and skittering softly along the ground in a light "
                "gust of wind, then settling, gentle, no footsteps",
        "duration_seconds": 5, "prompt_influence": 0.5, "output_format": _SFX_FMT}},
}

# Model comparison for the menu track (not used by any asset; its cached WAV was deleted and
# fetch_fal.py does not request it). Kept for the record in docs/AUDIO.md.
COMPARISON = {
    "music_menu_sa3": {"model": SA3, "params": {
        "prompt": _MENU_PROMPT, "negative_prompt": "vocals, singing, voice, choir, speech, "
        "distortion, harsh, noisy, low quality, fade out", "duration": 150,
        "output_format": "wav", "seed": 8401}},
}
