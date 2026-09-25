"""Attempt the existing calibration gate and freeze a diagnostic review, without weakening it."""
import argparse
from pathlib import Path

from dataset import load_dataset
from learning import calibrate, load_checkpoint
from pipeline import export
from pipeline_io import PipelineError, require, write_new
from review_support import make_report, partition_summary


def build_report(run):
    run = Path(run)
    require(not (run / "report.json").exists(), "review report already frozen")
    data = load_dataset(run / "dataset.json")
    require(data["mode"] == "approved", "this review requires approved training data")
    checkpoints, statuses = {}, {}
    for name in ("v1", "v2"):
        checkpoint = load_checkpoint(run / name / "fitted.json", data)
        try:
            checkpoint = calibrate(checkpoint, data)
        except PipelineError as error:
            status = dict(status="blocked", reason=str(error), required_positions_per_class=100,
                          actual=partition_summary(data)["calibration"])
        else:
            write_new(run / name / "calibrated.json", checkpoint)
            export(checkpoint, run / name / "export")
            status = dict(status="completed", quality_claim=False)
        write_new(run / name / "calibration_status.json", status)
        statuses[name], checkpoints[name] = status, checkpoint
    report = make_report(data, checkpoints, statuses)
    write_new(run / "report.json", report)
    print("Review report saved; calibration state is explicit; release_ready=false.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, type=Path)
    build_report(parser.parse_args().run)
