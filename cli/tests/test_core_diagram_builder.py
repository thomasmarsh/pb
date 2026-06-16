from pb_cli.core.diagram_builder import complexity_color, kind_color


def test_complexity_color_low():
    c = complexity_color(0)
    assert c.startswith("#")


def test_complexity_color_high():
    c = complexity_color(30)
    assert c.startswith("#")


def test_kind_color_powerscript():
    assert kind_color("powerscript") == "#5B8DD9"


def test_kind_color_unknown():
    assert kind_color("bogus") == "#D0D0D0"
