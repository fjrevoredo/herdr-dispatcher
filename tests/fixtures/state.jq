# Synthetic protocol records. Paths are supplied by each private sandbox.
def occupant($pane; $terminal; $session; $group):
 {pane_id:$pane,terminal_id:$terminal,kind:"pi",agent_session:{agent:"pi",kind:"path",source:"herdr:pi",value:($root+"/"+$session)},foreground_process_group_id:$group};
def attempt: {phase:"none",attempt_id:null,started_at:null,acknowledged_at:null,error:null};
def base: {schema_version:1,revision:0,created_at:$at,updated_at:$at,error:null};
def launch($id; $name; $role; $cwd; $tab; $pane; $identity):
 base + {launch_id:$id,target:(if $role == null then "dispatcher" else "worker" end),name:$name,role:$role,kind:"pi",cwd:$cwd,config_path:$config,ownership_token:$id,ownership_mode:"created",phase:"ready",mutation:null,workspace_id:"wDispatch",tab_id:$tab,pane_id:$pane,identity:$identity,human_notified:false};
occupant("wTest:p1";"term_test";"requester.jsonl";4200) as $requester |
occupant("wDispatch:p2";"term_worker";"worker.jsonl";5200) as $worker |
"11111111111111111111111111111111" as $workspace_token |
"22222222222222222222222222222222" as $worker_token |
{
 requester:$requester,worker_identity:$worker,
 status:(base + {run_id:$id,state:"new",assignment:null,worker_release:{phase:"none",observed_at:null,reason:null},delivery:attempt,nudge:(attempt + {settled_observed_at:null}),notice:{type:null,phase:"none",attempts:0,last_attempt_at:null,attempt_id:null,in_flight:false,last_outcome:null,error:null},human:{attention:false,missing_requester:false,late_result:false}}),
 request:{schema_version:1,run_id:$id,from_pane:$requester.pane_id,requester:$requester,cwd:($root+"/work"),created_at:$at,role:"review"},
 assignment:{assignment_id:"33333333333333333333333333333333",worker_name:"review-1",role:"review",kind:"pi",cwd:($root+"/work"),worker:$worker,assigned_at:$at},
 report:{schema_version:1,run_id:$id,worker_name:"review-1",assignment_id:"33333333333333333333333333333333",worker:$worker,created_at:$at},
 workspace:(base + {label:"dispatch",ownership_token:$workspace_token,launch_id:$workspace_token,workspace_id:"wDispatch",initial_tab_id:"tDispatch",initial_pane_id:"wDispatch:p1",config_path:$config,lifecycle:"ready"}),
 workspace_launch:launch($workspace_token;"dispatcher";null;($root+"/repo");"tDispatch";"wDispatch:p1";occupant("wDispatch:p1";"term_dispatcher";"dispatcher.jsonl";6200)),
 worker_launch:launch($worker_token;"review-1";"review";($root+"/work");"tWorker";"wDispatch:p2";$worker),
 worker:(base + {name:"review-1",role:"review",kind:"pi",cwd:($root+"/work"),config_path:$config,ownership:{mode:"created",token:$worker_token,launch_id:$worker_token},workspace_id:"wDispatch",tab_id:"tWorker",pane_id:"wDispatch:p2",identity:$worker,lifecycle:"idle",active_run_id:null,idle_since:$at})
}
