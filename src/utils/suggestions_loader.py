import yaml
import logging
from pathlib import Path
from typing import Dict, Optional, Any

logger = logging.getLogger(__name__)


class SuggestionsLoader:
    """Load and manage handling suggestions from YAML file"""
    
    def __init__(self, suggestions_file: str):
        self.suggestions_file = suggestions_file
        self.suggestions: Dict[str, Any] = {}
        self.load_suggestions()
    
    def load_suggestions(self):
        """Load suggestions from YAML file"""
        logger.info("=" * 60)
        logger.info(f"SuggestionsLoader: Loading from {self.suggestions_file}")
        
        try:
            if not Path(self.suggestions_file).exists():
                logger.error(f"Suggestions file NOT FOUND: {self.suggestions_file}")
                logger.info("=" * 60)
                return
            
            logger.info("File exists, reading...")
            
            with open(self.suggestions_file, 'r', encoding='utf-8') as f:
                content = f.read()
            
            logger.info(f"Content length: {len(content)} bytes")
            
            # Parse YAML
            raw_suggestions = yaml.safe_load(content)
            
            if raw_suggestions is None:
                logger.warning("yaml.safe_load returned None")
                self.suggestions = {}
            elif not isinstance(raw_suggestions, dict):
                logger.error(f"Unexpected type: {type(raw_suggestions)}")
                self.suggestions = {}
            else:
                # Convert all keys to strings (YAML may parse numbers as int)
                self.suggestions = {str(k): v for k, v in raw_suggestions.items()}
                logger.info(f"SUCCESS: Loaded {len(self.suggestions)} entries")
                logger.info(f"Keys (as strings): {list(self.suggestions.keys())}")
                
                if self.suggestions:
                    first_key = list(self.suggestions.keys())[0]
                    logger.info(f"First entry key type: {type(first_key)}")
                    logger.info(f"First entry ({first_key}): {self.suggestions[first_key]}")
            
        except Exception as e:
            logger.error(f"EXCEPTION: {e}", exc_info=True)
            self.suggestions = {}
        
        logger.info(f"Final count: {len(self.suggestions)}")
        logger.info("=" * 60)
    
    def get_suggestion(self, target_code: str) -> Optional[Dict[str, Any]]:
        """Get suggestion for specific target code"""
        if not self.suggestions:
            logger.warning(f"No suggestions loaded. Requested: {target_code}")
            return None
        
        # Ensure target_code is string for lookup
        target_code_str = str(target_code)
        
        if target_code_str not in self.suggestions:
            available = list(self.suggestions.keys())[:5]
            logger.debug(f"Not found: {target_code_str}. Available: {available}")
            return None
        
        suggestion = self.suggestions[target_code_str]
        
        return {
            "title": suggestion.get("title", "Unknown"),
            "desc": suggestion.get("desc", "No description"),
            "according": suggestion.get("according", "N/A"),
            "suggestions": suggestion.get("suggestions", "No suggestions")
        }
    
    def get_all_codes(self) -> list:
        """Get all available target codes"""
        return list(self.suggestions.keys())
