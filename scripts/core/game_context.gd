extends Node

# シーン間でテラリウム選択状態を保持する autoload シングルトン。
# TopPage → Editor → TopPage → Main(Sim) の遷移で使う。
# -1 = 未選択(直接 Main を叩いた場合はデフォルトテラリウムにフォールバック)。

var selected_terrarium_id: int = -1
# リプレイ閲覧用。RunTimeline.tscn を開くときに RunBrowser からセットする。
var selected_run_id: int = -1
